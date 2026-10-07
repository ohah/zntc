//! 단일 소스 트랜스파일 — I/O 없는 순수 함수.
//!
//! 입력: 소스 문자열 + 파일 경로(확장자 감지용) + 옵션
//! 출력: 변환된 JS 코드 (allocator 소유, caller가 free)
//!
//! 용도:
//!   - main.zig의 CLI transpileFile에서 핵심 로직으로 사용
//!   - bundler에서 폴리필 Flow strip
//!   - 향후 NAPI 바인딩의 단일 파일 API

const std = @import("std");
const Scanner = @import("lexer/mod.zig").Scanner;
const Parser = @import("parser/parser.zig").Parser;
const ast_mod = @import("parser/ast.zig");
const Ast = ast_mod.Ast;
const ast_walk = @import("parser/ast_walk.zig");
const SemanticAnalyzer = @import("semantic/mod.zig").SemanticAnalyzer;
const Transformer = @import("transformer/transformer.zig").Transformer;
const es_helpers = @import("transformer/es_helpers.zig");
const runtime_helper_names = @import("runtime_helper_names.zig");
const TransformOptions = @import("transformer/transformer.zig").TransformOptions;
const BindingLite = @import("transformer/transformer.zig").BindingLite;
const Codegen = @import("codegen/codegen.zig").Codegen;
const cg_options = @import("codegen/options.zig");
const SourceMap = @import("codegen/sourcemap.zig");
const Mangler = @import("codegen/mod.zig").mangler;
const module_parser = @import("parser/module.zig");
const ts_auto_export = @import("parser/ts_auto_export.zig");
const qualified_type_name = @import("transformer/qualified_type_name.zig");
const LinkingMetadata = @import("bundler/linker.zig").LinkingMetadata;
const rt = @import("bundler/runtime_helpers.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const OwnedDiagnostic = @import("diagnostic.zig").OwnedDiagnostic;
const string_list = @import("util/string_list.zig");
const debug_log = @import("debug_log.zig");
const transpile_options = @import("transpile/options.zig");

pub const StopAfter = transpile_options.StopAfter;
pub const TranspileOptions = transpile_options.TranspileOptions;
pub const ConfigOptionsDto = transpile_options.ConfigOptionsDto;
pub const TranspileOptionsDto = transpile_options.TranspileOptionsDto;
pub const AliasDto = transpile_options.AliasDto;
pub const ManualChunkDto = transpile_options.ManualChunkDto;
pub const LoaderDto = transpile_options.LoaderDto;
pub const MfConfigDto = transpile_options.MfConfigDto;
pub const validateMf = transpile_options.validateMf;
pub const applyTranspileSharedFields = transpile_options.applyTranspileSharedFields;
pub const optionsFromJson = transpile_options.optionsFromJson;

const SemanticRequirement = enum {
    none,
    bindings,
    full,
};

const SemanticPlanReason = enum {
    simple_ts_strip,
    disabled_by_env,
    stop_after_semantic,
    non_ts_source,
    flow_source,
    jsx_source,
    option_requires_transform_semantic,
    target_requires_downlevel,
    module_format_requires_semantic,
    ast_requires_runtime_transform,
    import_shape_requires_full_semantic,
    binding_shadow_requires_full_semantic,
    named_import_binding_elision,
};

const TransformPlan = struct {
    semantic: SemanticRequirement,
    reason: SemanticPlanReason,
    strip_types_only: bool = false,
};

/// `buildTransformPlan` 의 게이팅 입력. 각 플래그는 plan 분기에서 1회씩만 소비되므로,
/// 카테고리별로 묶어 둔다 (개별 tag 단위 정보가 필요해지면 분리).
const AstFacts = struct {
    /// `import_declaration` 노드 존재 여부. binding-lite elision 가능성 판정.
    has_import_declaration: bool = false,
    /// default / namespace import — binding-lite 는 named 만 다루므로 모두 full path 로 위임.
    has_non_named_import: bool = false,
    /// class / private / decorator / TS runtime syntax / using — runtime transform needed.
    has_runtime_sensitive_syntax: bool = false,
    /// Runtime transforms whose graph edits are not certified for Flow-mode input yet.
    has_flow_runtime_syntax_without_complete_graph: bool = false,
    /// Runtime syntax whose semantic edits still need the post-transform analyzer.
    has_unhandled_runtime_syntax: bool = false,
    /// Qualified metadata names with spellings the transform graph cannot yet
    /// split into exact base references and property names.
    has_unsupported_qualified_metadata_type_reference: bool = false,
};

pub const TranspileError = error{
    ParseError,
    SemanticError,
    TransformError,
    CodegenError,
    OutOfMemory,
};

/// 에러 발생 시 호출되는 콜백. scanner와 source가 유효한 동안 호출됨.
/// main.zig에서 코드 프레임 출력용으로 사용.
pub const ErrorCallback = *const fn (
    source: []const u8,
    file_path: []const u8,
    scanner: *const Scanner,
    errors: []const Diagnostic,
) void;

pub const TranspileResult = struct {
    /// 변환된 JS 코드. allocator 소유.
    code: []const u8,
    /// 소스맵 JSON (sourcemap=true일 때). allocator 소유. null이면 미생성.
    sourcemap: ?[]const u8 = null,
    /// 런타임 헬퍼 포함 여부
    has_helpers: bool = false,
    /// 시맨틱 에러 목록 (tsc 호환: codegen과 함께 반환).
    /// allocator 소유. 각 항목은 arena에서 복사된 OwnedDiagnostic.
    /// 파서 에러는 throw 경로라 여기 담기지 않는다 — on_error 콜백 참조.
    diagnostics: []const OwnedDiagnostic = &.{},
    /// 소스의 줄 시작 오프셋. diagnostics 렌더링에 필요.
    /// allocator 소유. diagnostics가 비었으면 비어 있을 수 있다.
    line_offsets: []const u32 = &.{},

    pub fn deinit(self: *TranspileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        if (self.sourcemap) |sm| allocator.free(sm);
        for (self.diagnostics) |d| d.deinit(allocator);
        if (self.diagnostics.len > 0) allocator.free(self.diagnostics);
        if (self.line_offsets.len > 0) allocator.free(self.line_offsets);
    }
};

// env-presence flag — 공용 제너릭 (RFC #3399 PR-3: 중복 boilerplate 통합).
const fast_path_disabled_env = @import("env_flag.zig").Once("ZNTC_DISABLE_TRANSPILE_FAST_PATH");

fn transpileFastPathDisabledByEnv() bool {
    return fast_path_disabled_env.enabled();
}

fn collectAstFacts(ast: *const Ast) AstFacts {
    var facts: AstFacts = .{};

    for (ast.nodes.items) |node| {
        switch (node.tag) {
            .import_declaration => facts.has_import_declaration = true,
            .import_default_specifier,
            .import_namespace_specifier,
            => facts.has_non_named_import = true,

            // Flow class lowering preserves source binding identities in the edited graph.
            .class_declaration, .class_expression => facts.has_runtime_sensitive_syntax = true,

            .private_identifier,
            .private_field_expression,
            => {
                facts.has_runtime_sensitive_syntax = true;
            },

            .accessor_property => facts.has_runtime_sensitive_syntax = true,

            // Stage 3 decorator lowering records generated bindings, references,
            // and class/decorator scopes in the edited semantic graph for Flow too.
            .decorator => facts.has_runtime_sensitive_syntax = true,

            // TypeScript enum lowering now records the emitted IIFE parameter
            // and initializer references in the edited semantic graph.
            .ts_enum_declaration => {
                facts.has_runtime_sensitive_syntax = true;
                facts.has_flow_runtime_syntax_without_complete_graph = true;
            },

            // Namespace IIFE parameters and exported binding edges are tracked
            // by SymbolId and emitted from that graph by codegen.
            .ts_module_declaration => {
                facts.has_runtime_sensitive_syntax = true;
                facts.has_flow_runtime_syntax_without_complete_graph = true;
            },

            // Import-equals is rewritten to a const declaration by the
            // transformer. Its binding and value references are retained in
            // the edited semantic graph, so it does not need post-transform
            // symbol reconstruction.
            .ts_import_equals_declaration => facts.has_runtime_sensitive_syntax = true,

            .ts_type_reference => {
                if (qualified_type_name.typeReferenceName(ast, node)) |name| {
                    if (std.mem.indexOfScalar(u8, name, '.') != null and
                        !qualified_type_name.isSimpleQualifiedPath(name))
                    {
                        facts.has_unsupported_qualified_metadata_type_reference = true;
                    }
                } else if (std.mem.indexOfScalar(u8, ast.getText(node.span), '.') != null) {
                    facts.has_unsupported_qualified_metadata_type_reference = true;
                }
            },

            // `export = expr` preserves its value reference; lowering adds a global `module`
            // reference and an ordinary `.exports` property name.
            .ts_export_assignment => facts.has_runtime_sensitive_syntax = true,

            // `export as namespace` is erased and carries no runtime references or bindings.
            .ts_namespace_export_declaration => facts.has_runtime_sensitive_syntax = true,

            // Flow match is fully lowered by the semantic editor: its generated
            // function scope, parameter symbol, arm scopes, and references are
            // already part of the transform graph.
            .flow_match_expression => facts.has_runtime_sensitive_syntax = true,

            // Flow enum declaration and references have exact source SymbolIds;
            // codegen emits the declaration name through the same symbol-aware path.
            .flow_enum_declaration => facts.has_runtime_sensitive_syntax = true,

            // Flow component-with-ref adds the helper binding and call reference
            // to the same transform graph, including when its body lowers JSX.
            .flow_component_wrapper => facts.has_runtime_sensitive_syntax = true,

            .variable_declaration => {
                if (ast.variableDeclarationKind(node).isUsing()) {
                    facts.has_runtime_sensitive_syntax = true;
                }
            },

            else => {},
        }
    }

    return facts;
}

// 한 함수 / 한 var 리스트 / 한 import 절에서 매칭되는 import 이름 수의 상한.
// 초과 시 scan 은 over-conservative 로 full route 를 택하고 mark 는 shadow 를 누락해도
// outer import 가 used 로 마킹되어 import 가 보존된다.
const binding_lite_max_shadows: usize = 64;

// default/namespace specifier 는 collectAstFacts 에서 has_non_named_import 로 잡혀
// buildTransformPlan 이 이미 full 로 라우팅하므로 여기서는 named 만 본다.
// import local 노드는 identifier_reference 로 태깅되므로 binding_identifier 필터에 자연히 빠진다.
// 함수 파라미터 / catch / block lexical shadow 는 binding-lite walker 가 scope-aware 로
// 처리한다. top-level shadow, `var` shadow, walker buffer overflow 처럼 declaration-order
// 또는 scope 의미가 애매한 케이스만 full 로 보낸다.
fn hasUnsupportedNamedImportLocalBindingShadow(ast: *const Ast) error{OutOfMemory}!bool {
    var names_buf: [binding_lite_max_shadows][]const u8 = undefined;
    var names_len: usize = 0;

    for (ast.nodes.items) |import_node| {
        if (import_node.tag != .import_declaration) continue;
        const import_decl = module_parser.readImportDeclExtras(ast, import_node.data.extra);
        if (import_decl.is_type_only) continue;
        var i: u32 = 0;
        while (i < import_decl.specs_len) : (i += 1) {
            const spec_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[import_decl.specs_start + i]);
            if (spec_idx.isNone()) continue;
            const spec = ast.getNode(spec_idx);
            if (spec.tag != .import_specifier) continue;
            if ((spec.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) continue;

            const local_idx = spec.data.binary.right;
            if (local_idx.isNone()) continue;
            // barrel 파일 등 비현실적 import 수는 보수적으로 full route.
            if (names_len == names_buf.len) return true;
            names_buf[names_len] = ast.getText(ast.getNode(local_idx).span);
            names_len += 1;
        }
    }

    if (names_len == 0) return false;

    for (ast.nodes.items, 0..) |node, raw_idx| {
        if (node.tag != .program) continue;
        return scanForUnsupportedBindingLiteShadow(ast, @enumFromInt(raw_idx), names_buf[0..names_len], 0, false, null);
    }
    return false;
}

// match_count 는 호출자가 누적한다. binding pattern 하나(=formal_parameters/catch param)
// 안에서는 fresh counter 로도 의미가 같지만, `var a, b, c` 처럼 한 var 리스트의
// 누적 shadow 수를 봐야 하는 경우엔 호출자가 같은 counter 를 재사용한다.
fn bindingPatternImportShadowOverflow(ast: *const Ast, idx: ast_mod.NodeIndex, names: []const []const u8, match_count: *usize) error{OutOfMemory}!bool {
    var it = try ast_walk.bindingIdentifiers(ast.allocator, ast, idx, .{ .cover_grammar_assignment = true });
    defer it.deinit();
    while (try it.next()) |leaf_idx| {
        const leaf = ast.getNode(leaf_idx);
        const name = ast.getText(leaf.span);
        if (string_list.contains(names, name)) {
            match_count.* += 1;
            if (match_count.* > binding_lite_max_shadows) return true;
        }
    }
    return false;
}

fn functionExpressionInnerName(ast: *const Ast, node: ast_mod.Node) ?[]const u8 {
    if (node.tag != .function_expression and node.tag != .function) return null;
    const name_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[node.data.extra]);
    if (name_idx.isNone()) return null;
    return ast.getText(ast.getNode(name_idx).span);
}

fn functionExpressionNameImportShadowOverflow(ast: *const Ast, node: ast_mod.Node, names: []const []const u8, match_count: *usize) bool {
    const name = functionExpressionInnerName(ast, node) orelse return false;
    if (string_list.contains(names, name)) {
        match_count.* += 1;
        if (match_count.* > binding_lite_max_shadows) return true;
    }
    return false;
}

// 함수 body 안에서 nested function/arrow 를 건너뛰며 non-lexical `var` 선언의 binding pattern 을
// 모두 방문한다. visitor 가 true 를 반환하면 즉시 abort. overflow 검사 / shadow 수집 두 사용처가
// 동일 트리 순회를 공유하도록 모은 헬퍼.
fn walkFunctionVarBindingPatterns(
    ast: *const Ast,
    idx: ast_mod.NodeIndex,
    ctx: anytype,
    comptime onBindingPattern: fn (@TypeOf(ctx), ast_mod.NodeIndex) error{OutOfMemory}!bool,
) error{OutOfMemory}!bool {
    // 반복 worklist(#4123): 깊은 좌결합 체인을 재귀로 내려가면 스택 오버플로우. scope state 가
    // 없어(function 경계 prune + var-decl 콜백 + else descend) 단순 NodeIndex 스택이면 충분.
    // comptime 콜백 + error 전파 때문에 walkPreorderIterative(비-erroring visit) 대신 inline.
    var stack: std.ArrayListUnmanaged(ast_mod.NodeIndex) = .empty;
    defer stack.deinit(ast.allocator);
    try stack.append(ast.allocator, idx);
    var child_buf: std.ArrayListUnmanaged(ast_mod.NodeIndex) = .empty;
    defer child_buf.deinit(ast.allocator);

    while (stack.pop()) |cur| {
        if (cur.isNone() or @intFromEnum(cur) >= ast.nodes.items.len) continue;
        const node = ast.getNode(cur);
        switch (node.tag) {
            // function/arrow scope 경계 — var 는 함수 밖으로 안 샘. prune(자식 안 봄).
            .function_declaration,
            .function_expression,
            .function,
            .arrow_function_expression,
            => continue,
            .variable_declaration => if (!ast.variableDeclarationKind(node).isLexical()) {
                const list_start = ast.extra_data.items[node.data.extra + 1];
                const list_len = ast.extra_data.items[node.data.extra + 2];
                var i: u32 = 0;
                while (i < list_len) : (i += 1) {
                    const decl_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[list_start + i]);
                    if (decl_idx.isNone()) continue;
                    const decl = ast.getNode(decl_idx);
                    if (decl.tag != .variable_declarator) continue;
                    if (try onBindingPattern(ctx, @enumFromInt(ast.extra_data.items[decl.data.extra]))) return true;
                }
                // var-decl 도 자식(init 등) 계속 descend — 아래 child push 로 (원본 fall-through).
            },
            else => {},
        }
        try ast_walk.collectChildrenInto(ast, node, &child_buf, ast.allocator);
        var i = child_buf.items.len;
        while (i > 0) {
            i -= 1;
            try stack.append(ast.allocator, child_buf.items[i]);
        }
    }
    return false;
}

fn scanVariableDeclarationForUnsupportedBindingLiteShadow(
    ast: *const Ast,
    node: ast_mod.Node,
    names: []const []const u8,
    scope_depth: usize,
    inside_function: bool,
    fn_shadow_count: ?*usize,
) error{OutOfMemory}!bool {
    const list_start = ast.extra_data.items[node.data.extra + 1];
    const list_len = ast.extra_data.items[node.data.extra + 2];
    // 함수 scope 안이면 호출자가 누적 카운터를 넘기고, 모듈 scope 면 statement 로컬 카운터로 폴백.
    // before snapshot 은 lex/non-lex top-level fallback 결정에 쓰는 statement-local 카운트를 분리해
    // 둔다 — 같은 함수의 다른 var statement 가 누적한 값을 자기 것으로 오인하지 않게.
    var local_count: usize = 0;
    const counter = fn_shadow_count orelse &local_count;
    const before = counter.*;
    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const decl_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[list_start + i]);
        if (decl_idx.isNone()) continue;
        const decl = ast.getNode(decl_idx);
        if (decl.tag != .variable_declarator) continue;
        const binding_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[decl.data.extra]);
        if (try bindingPatternImportShadowOverflow(ast, binding_idx, names, counter)) return true;
        const init_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[decl.data.extra + 2]);
        if (try scanForUnsupportedBindingLiteShadow(ast, init_idx, names, scope_depth, inside_function, fn_shadow_count)) return true;
    }

    if (counter.* == before) return false;
    if (ast.variableDeclarationKind(node).isLexical()) return scope_depth == 0;
    return !inside_function;
}

/// scanForUnsupportedBindingLiteShadow 의 switch 가 tag 별로 특수 처리(=scope state 변경 또는
/// bespoke binding 검사)하는 노드인지. 이 노드들은 반복 평탄화에서 recursive scanForUnsupported
/// 로 위임한다(scope 중첩은 얕음). 그 외(generic expression 등)는 scanForUnsupported 가 곧
/// scanChildren(같은 state) 이므로 worklist 가 자식을 직접 push 해 평탄화.
///
/// ⚠️ 이 집합은 scanForUnsupportedBindingLiteShadow switch 의 **non-`else` arm 전부**와 정확히
/// 일치해야 한다. 빠지면(과거 .variable_declaration/.binding_identifier 누락) 그 노드가 generic
/// 으로 처리돼 top-level lexical shadow / binding-name 검사를 건너뛴다(→ `.bindings` 오판,
/// `import { Foo } from …; const Foo = 1` 가 full semantic 으로 안 올라감). 단위 테스트
/// "ambiguous or overflowing named import shadows keep full semantic" 가 drift 를 잡는다.
fn isScopeOrSpecialForBindingLite(tag: ast_mod.Node.Tag) bool {
    return switch (tag) {
        .program,
        .block_statement,
        .function_body,
        .formal_parameters,
        .catch_clause,
        .function_declaration,
        .function_expression,
        .function,
        .arrow_function_expression,
        .variable_declaration,
        .binding_identifier,
        => true,
        else => false,
    };
}

fn scanChildrenForUnsupportedBindingLiteShadow(
    ast: *const Ast,
    node: ast_mod.Node,
    names: []const []const u8,
    child_scope_depth: usize,
    inside_function: bool,
    fn_shadow_count: ?*usize,
) error{OutOfMemory}!bool {
    // 반복 worklist(#4123): 원본은 scanForUnsupported↔scanChildren 상호재귀라 깊은 좌결합 체인
    // (`+` 등, 같은 scope state)에서 스택 오버플로우였다(실측 — named-import + 40000항). generic
    // 노드는 scanForUnsupported(generic)=scanChildren(같은 state) 이므로 자식을 직접 push 해
    // 평탄화하고, scope/special 노드만 recursive scanForUnsupported 로 위임(scope 중첩=얕음).
    // worklist state(child_scope_depth/inside_function/fn_shadow_count)는 generic descent 내내
    // 불변이라 단순 NodeIndex 스택으로 충분(scope 노드는 자체 재귀로 state 재유도).
    const Push = struct {
        fn go(
            a: *const Ast,
            n: ast_mod.Node,
            st: *std.ArrayListUnmanaged(ast_mod.NodeIndex),
            cb: *std.ArrayListUnmanaged(ast_mod.NodeIndex),
        ) error{OutOfMemory}!void {
            try ast_walk.collectChildrenInto(a, n, cb, a.allocator);
            var i = cb.items.len; // 소스 순서 보존: 역순 push → LIFO pop 이 forward
            while (i > 0) {
                i -= 1;
                try st.append(a.allocator, cb.items[i]);
            }
        }
    };

    var stack: std.ArrayListUnmanaged(ast_mod.NodeIndex) = .empty;
    defer stack.deinit(ast.allocator);
    var child_buf: std.ArrayListUnmanaged(ast_mod.NodeIndex) = .empty;
    defer child_buf.deinit(ast.allocator);

    try Push.go(ast, node, &stack, &child_buf); // seed: node 의 직계 자식 (원본 순회 대상)

    while (stack.pop()) |cur| {
        if (cur.isNone() or @intFromEnum(cur) >= ast.nodes.items.len) continue;
        const cnode = ast.getNode(cur);
        if (isScopeOrSpecialForBindingLite(cnode.tag)) {
            if (try scanForUnsupportedBindingLiteShadow(ast, cur, names, child_scope_depth, inside_function, fn_shadow_count)) return true;
        } else {
            try Push.go(ast, cnode, &stack, &child_buf);
        }
    }
    return false;
}

// 함수/arrow scope 의 params + body 를 같은 카운터로 한 번씩만 순회. arrow 와 function 양쪽이 공유.
fn scanFunctionScopeParamsAndBody(
    ast: *const Ast,
    params_idx: ast_mod.NodeIndex,
    body_idx: ast_mod.NodeIndex,
    names: []const []const u8,
    scope_depth: usize,
    inside_function: bool,
    fn_shadow_count: *usize,
) error{OutOfMemory}!bool {
    if (try scanForUnsupportedBindingLiteShadow(ast, params_idx, names, scope_depth, inside_function, fn_shadow_count)) return true;
    return scanForUnsupportedBindingLiteShadow(ast, body_idx, names, scope_depth + 1, true, fn_shadow_count);
}

fn scanFunctionForUnsupportedBindingLiteShadow(
    ast: *const Ast,
    node: ast_mod.Node,
    names: []const []const u8,
    scope_depth: usize,
    inside_function: bool,
) error{OutOfMemory}!bool {
    const e = node.data.extra;
    // function_expression / function 의 extras[0] 은 inner-only self-name 이라 outer scope binding
    // 으로 스캔하면 안 되고 함수-스코프 카운터에만 누적한다. function_declaration 은 extras[0] 이
    // outer 에 노출되는 binding 이므로 일반 스캔 경로 (fn_shadow_count=null) 를 그대로 탄다.
    const is_function_expression = node.tag != .function_declaration;
    // 한 함수 scope 안에서 누적되는 shadow 수. 함수-식 self-name + params + body 안 var binding 합산.
    // BindingLite collector (markBindingLiteFunctionScope) 가 모으는 set 과 동일 — overflow 시 fallback.
    var fn_shadow_count: usize = 0;
    if (is_function_expression and functionExpressionNameImportShadowOverflow(ast, node, names, &fn_shadow_count)) return true;
    if (!is_function_expression and try scanForUnsupportedBindingLiteShadow(ast, @enumFromInt(ast.extra_data.items[e]), names, scope_depth, inside_function, null)) return true;
    return scanFunctionScopeParamsAndBody(
        ast,
        @enumFromInt(ast.extra_data.items[e + 1]),
        @enumFromInt(ast.extra_data.items[e + 2]),
        names,
        scope_depth,
        inside_function,
        &fn_shadow_count,
    );
}

fn scanForUnsupportedBindingLiteShadow(
    ast: *const Ast,
    idx: ast_mod.NodeIndex,
    names: []const []const u8,
    scope_depth: usize,
    inside_function: bool,
    fn_shadow_count: ?*usize,
) error{OutOfMemory}!bool {
    if (idx.isNone()) return false;
    const node = ast.getNode(idx);
    switch (node.tag) {
        // scope_depth: program 은 0, block/body 진입마다 +1. inside_function: function/arrow body
        // 이하 ancestry. 두 값을 함께 쓰는 이유는 scanVariableDeclarationForUnsupp 의 return 두 줄이
        // truth table — top-level lexical (lex && depth==0) 또는 모듈-스코프 var (!lex && !inside_function)
        // 만 import 를 가리는 fallback 조건이고, 함수 내 var 는 nearest function scope 에만 머물러 outer
        // use 를 안 가린다.
        .program => return scanChildrenForUnsupportedBindingLiteShadow(ast, node, names, 0, false, null),
        .block_statement => return scanChildrenForUnsupportedBindingLiteShadow(ast, node, names, scope_depth + 1, inside_function, fn_shadow_count),
        .function_body => return scanChildrenForUnsupportedBindingLiteShadow(ast, node, names, scope_depth + 1, true, fn_shadow_count),
        .formal_parameters => {
            var local_count: usize = 0;
            const counter = fn_shadow_count orelse &local_count;
            return bindingPatternImportShadowOverflow(ast, idx, names, counter);
        },
        .catch_clause => {
            // catch 매개변수는 catch block scope 에만 binding 되어 BindingLite 의 함수-scope shadow set
            // 에 합산되지 않는다. 단일 catch 안 overflow 만 별도 fresh counter 로 검사한다.
            var local_count: usize = 0;
            if (try bindingPatternImportShadowOverflow(ast, node.data.binary.left, names, &local_count)) return true;
            return scanForUnsupportedBindingLiteShadow(ast, node.data.binary.right, names, scope_depth + 1, inside_function, fn_shadow_count);
        },
        .function_declaration,
        .function_expression,
        .function,
        => return scanFunctionForUnsupportedBindingLiteShadow(ast, node, names, scope_depth, inside_function),
        .arrow_function_expression => {
            const e = node.data.extra;
            // arrow 도 자기 function scope 를 가지므로 새 카운터를 연다. function 과 같은 헬퍼 공유.
            var arrow_shadow_count: usize = 0;
            return scanFunctionScopeParamsAndBody(
                ast,
                @enumFromInt(ast.extra_data.items[e]),
                @enumFromInt(ast.extra_data.items[e + 1]),
                names,
                scope_depth,
                inside_function,
                &arrow_shadow_count,
            );
        },
        .variable_declaration => return scanVariableDeclarationForUnsupportedBindingLiteShadow(ast, node, names, scope_depth, inside_function, fn_shadow_count),
        .binding_identifier => return string_list.contains(names, ast.getText(node.span)),
        else => return scanChildrenForUnsupportedBindingLiteShadow(ast, node, names, scope_depth, inside_function, fn_shadow_count),
    }
}

fn optionsRequireTransformSemantic(options: TranspileOptions) bool {
    return options.minify_identifiers or
        options.minify_syntax or
        options.minify_whitespace or
        options.drop_console or
        options.drop_debugger or
        options.define.len > 0 or
        !options.use_define_for_class_fields or
        options.experimental_decorators or
        options.emit_decorator_metadata or
        options.react_refresh or
        options.react_refresh_hook_signatures;
}

/// The transform semantic editor carries identifier IDs, references, and output
/// scopes through JavaScript and TypeScript lowering paths whose semantic edits
/// are complete, including enum IIFEs and React Refresh registrations. Refresh
/// handles and hook signatures are added before `finishSemanticEdit`; their
/// component refs carry source SymbolIds and their runtime hooks are explicit
/// globals. Keep still-unhandled runtime-generating TS/Flow constructs outside
/// this graph until their edits are complete.
fn canMangleWithTransformSemantic(options: TranspileOptions, parser: *const Parser) bool {
    if (!options.minify_identifiers) return false;

    // emitDecoratorMetadata is currently modeled for TypeScript legacy
    // decorators. Other parser modes/options stay on the established analyzer.
    if (options.emit_decorator_metadata and
        (parser.is_flow or parser.source_mode != .ts or !options.experimental_decorators)) return false;

    // The exact transform graph now covers TypeScript's legacy decorator
    // lowering. Keep Flow and JavaScript decorator modes gated until their
    // corresponding lowering paths receive the same exact-identity audit.
    if (options.experimental_decorators and (parser.is_flow or parser.source_mode != .ts)) return false;

    const facts = collectAstFacts(&parser.ast);
    if (parser.is_flow) return !facts.has_flow_runtime_syntax_without_complete_graph;
    if (parser.source_mode == .ts) {
        return !facts.has_unhandled_runtime_syntax and
            !(options.emit_decorator_metadata and facts.has_unsupported_qualified_metadata_type_reference);
    }
    if (parser.source_mode != .js_strict) return false;
    return true;
}

/// Single-file CommonJS codegen emits these free identifiers after the transform
/// semantic graph is built. Reserve them before mangling so a source binding cannot
/// be assigned one of those names, just as the post-transform analyzer used to do.
fn reserveCommonJsCodegenNames(allocator: std.mem.Allocator, reserved: *std.StringHashMapUnmanaged(void)) !void {
    const names = [_][]const u8{
        cg_options.default_cjs_exports_name,
        cg_options.default_cjs_module_name,
        "require",
        "Object",
        "__dirname",
        "__filename",
    };
    for (names) |name| try reserved.put(allocator, name, {});
}

/// New explicit-global references created during lowering are not present in
/// the parser's unresolved-name table. Reserve their names when the edited
/// transform graph drives mangling so a generated global cannot be captured.
fn reserveGeneratedExternalNames(
    allocator: std.mem.Allocator,
    reserved: *std.StringHashMapUnmanaged(void),
    ast: *const Ast,
    root: ast_mod.NodeIndex,
    symbol_ids: []const ?u32,
    explicit_global_nodes: *const std.AutoHashMapUnmanaged(u32, void),
) !void {
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, ast, root);
    defer allocator.free(reachable);
    var reachable_set: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer reachable_set.deinit(allocator);
    for (reachable) |raw| try reachable_set.put(allocator, raw, {});

    var it = explicit_global_nodes.keyIterator();
    while (it.next()) |key| {
        const raw = key.*;
        if (!reachable_set.contains(raw) or raw >= ast.nodes.items.len) continue;
        if (raw < symbol_ids.len and symbol_ids[raw] != null) continue;
        const node = ast.nodes.items[raw];
        switch (node.tag) {
            .identifier_reference, .assignment_target_identifier => {},
            else => continue,
        }
        const name = ast.getText(node.data.string_ref);
        if (name.len > 0) try reserved.put(allocator, name, {});
    }
}

/// Flow enum codegen inserts these free identifiers without AST reference
/// nodes. Reserve them so minified source bindings cannot capture the runtime.
fn reserveFlowEnumCodegenNames(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    reserved: *std.StringHashMapUnmanaged(void),
) error{OutOfMemory}!void {
    for (ast.nodes.items) |node| {
        if (node.tag != .flow_enum_declaration) continue;
        try reserved.put(allocator, "require", {});
        try reserved.put(allocator, "Symbol", {});
        return;
    }
}

fn buildTransformPlan(
    options: TranspileOptions,
    parser: *const Parser,
    ast: *const Ast,
    fast_path_disabled: bool,
) error{OutOfMemory}!TransformPlan {
    if (fast_path_disabled) return .{ .semantic = .full, .reason = .disabled_by_env };
    if (options.stop_after == .semantic) return .{ .semantic = .full, .reason = .stop_after_semantic };

    // Flow 는 `non_ts_source` 보다 먼저 분류 — `// @flow` 주석이 붙은 `.js` 입력이
    // generic JS fallback 으로 잘못 집계되지 않도록 한다.
    if (parser.is_flow) return .{ .semantic = .full, .reason = .flow_source };
    // JS 파일은 보존 의미가 TS 와 달라 (값 import 가 type-only 라도 side-effect 가능 등)
    // fast path 적용 범위에서 제외 — full semantic 경로에서 진단 손실 없이 처리.
    if (parser.source_mode != .ts) return .{ .semantic = .full, .reason = .non_ts_source };
    if (ast.has_jsx) return .{ .semantic = .full, .reason = .jsx_source };

    if (optionsRequireTransformSemantic(options)) {
        return .{ .semantic = .full, .reason = .option_requires_transform_semantic };
    }
    if (options.unsupported.hasAny() or options.es_target != null) {
        return .{ .semantic = .full, .reason = .target_requires_downlevel };
    }
    if (options.module_format != .esm) {
        return .{ .semantic = .full, .reason = .module_format_requires_semantic };
    }

    // 파서가 `export = expr` 을 NodeIndex.none 으로 drop 하므로 (parser/module.zig) AST tag
    // 검사로는 잡을 수 없음 — 소스 substring 으로만 감지 가능. 이후 facts 게이트보다 비싼
    // 스캔이지만, runtime-sensitive 검사보다 먼저 short-circuit 되는 편이 일관됨.
    if (std.mem.indexOf(u8, ast.source, "export =") != null) {
        return .{ .semantic = .full, .reason = .ast_requires_runtime_transform };
    }

    const facts = collectAstFacts(ast);
    if (facts.has_non_named_import) {
        return .{ .semantic = .full, .reason = .import_shape_requires_full_semantic };
    }
    if (facts.has_runtime_sensitive_syntax) {
        return .{ .semantic = .full, .reason = .ast_requires_runtime_transform };
    }
    if (facts.has_import_declaration) {
        if (try hasUnsupportedNamedImportLocalBindingShadow(ast)) {
            return .{ .semantic = .full, .reason = .binding_shadow_requires_full_semantic };
        }
        return .{
            .semantic = .bindings,
            .reason = .named_import_binding_elision,
            .strip_types_only = true,
        };
    }

    return .{
        .semantic = .none,
        .reason = .simple_ts_strip,
        .strip_types_only = true,
    };
}

fn collectBindingLite(allocator: std.mem.Allocator, ast: *const Ast) !BindingLite {
    var bindings: std.ArrayList(BindingLite.NamedImport) = .empty;
    errdefer bindings.deinit(allocator);

    for (ast.nodes.items) |node| {
        if (node.tag != .import_declaration) continue;
        const import_decl = module_parser.readImportDeclExtras(ast, node.data.extra);
        if (import_decl.is_type_only) continue;
        var i: u32 = 0;
        while (i < import_decl.specs_len) : (i += 1) {
            const spec_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[import_decl.specs_start + i]);
            if (spec_idx.isNone()) continue;
            const spec = ast.getNode(spec_idx);
            if (spec.tag != .import_specifier) continue;
            if ((spec.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) continue;

            const local_idx = spec.data.binary.right;
            if (local_idx.isNone()) continue;
            const local = ast.getNode(local_idx);
            try bindings.append(allocator, .{ .local_name = ast.getText(local.span) });
        }
    }

    var lite = BindingLite{ .named_imports = try bindings.toOwnedSlice(allocator) };
    if (lite.named_imports.len == 0) return lite;
    const no_shadowed_names: []const []const u8 = &.{};
    for (ast.nodes.items, 0..) |node, raw_idx| {
        if (node.tag != .program) continue;
        try markBindingLiteValueUses(ast, @enumFromInt(raw_idx), &lite, true, no_shadowed_names);
        break;
    }
    return lite;
}

fn markBindingLiteUse(lite: *BindingLite, name: []const u8, shadowed_names: []const []const u8) void {
    if (string_list.contains(shadowed_names, name)) return;
    for (lite.named_imports) |*binding| {
        if (std.mem.eql(u8, binding.local_name, name)) {
            binding.used_as_value = true;
            return;
        }
    }
}

fn appendBindingLiteShadowName(buf: [][]const u8, len: *usize, name: []const u8) void {
    if (string_list.contains(buf[0..len.*], name)) return;
    // 상한 초과 shadow 는 그대로 두면 outer import 가 used 로 잘못 마킹될 위험이 있다 — over-conservative
    // 로 동작해 import 유지. 실제로는 한 함수에 binding_lite_max_shadows 개 동시 shadow 는 비현실적.
    if (len.* >= buf.len) return;
    buf[len.*] = name;
    len.* += 1;
}

fn collectBindingLitePatternShadows(ast: *const Ast, idx: ast_mod.NodeIndex, lite: *const BindingLite, buf: [][]const u8, len: *usize) error{OutOfMemory}!void {
    if (len.* >= buf.len) return;
    var it = try ast_walk.bindingIdentifiers(ast.allocator, ast, idx, .{ .cover_grammar_assignment = true });
    defer it.deinit();
    while (try it.next()) |leaf_idx| {
        const leaf = ast.getNode(leaf_idx);
        // import 이름과 매칭되는 binding 만 shadow set 에 추가. cover-grammar 결과인
        // identifier_reference / assignment_target_identifier 도 동일 처리.
        const name = ast.getText(leaf.span);
        if (lite.namedImportValueUse(name) != null) appendBindingLiteShadowName(buf, len, name);
    }
}

fn collectBindingLiteVariableDeclarationShadows(ast: *const Ast, node: ast_mod.Node, lite: *const BindingLite, buf: [][]const u8, len: *usize) error{OutOfMemory}!void {
    const list_start = ast.extra_data.items[node.data.extra + 1];
    const list_len = ast.extra_data.items[node.data.extra + 2];
    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const decl_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[list_start + i]);
        if (decl_idx.isNone()) continue;
        const decl = ast.getNode(decl_idx);
        if (decl.tag != .variable_declarator) continue;
        try collectBindingLitePatternShadows(ast, @enumFromInt(ast.extra_data.items[decl.data.extra]), lite, buf, len);
    }
}

fn collectBindingLiteFunctionVarShadows(ast: *const Ast, idx: ast_mod.NodeIndex, lite: *const BindingLite, buf: [][]const u8, len: *usize) error{OutOfMemory}!void {
    const Ctx = struct {
        ast: *const Ast,
        lite: *const BindingLite,
        buf: [][]const u8,
        len: *usize,
    };
    const visit = struct {
        fn onBindingPattern(c: Ctx, binding_idx: ast_mod.NodeIndex) error{OutOfMemory}!bool {
            try collectBindingLitePatternShadows(c.ast, binding_idx, c.lite, c.buf, c.len);
            // buf 가 가득 차면 더 append 해도 silent drop 이라 더 순회할 이유가 없다.
            return c.len.* >= c.buf.len;
        }
    }.onBindingPattern;
    _ = try walkFunctionVarBindingPatterns(
        ast,
        idx,
        Ctx{ .ast = ast, .lite = lite, .buf = buf, .len = len },
        visit,
    );
}

fn collectBindingLiteFunctionExpressionNameShadow(ast: *const Ast, node: ast_mod.Node, lite: *const BindingLite, buf: [][]const u8, len: *usize) void {
    const name = functionExpressionInnerName(ast, node) orelse return;
    if (lite.namedImportValueUse(name) != null) appendBindingLiteShadowName(buf, len, name);
}

fn collectBindingLiteListLexicalShadows(ast: *const Ast, list: ast_mod.NodeList, lite: *const BindingLite, buf: [][]const u8, len: *usize) error{OutOfMemory}!void {
    if (list.start + list.len > ast.extra_data.items.len) return;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const child_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[list.start + i]);
        if (child_idx.isNone()) continue;
        const child = ast.getNode(child_idx);
        if (child.tag == .variable_declaration and ast.variableDeclarationKind(child).isLexical()) {
            try collectBindingLiteVariableDeclarationShadows(ast, child, lite, buf, len);
        }
    }
}

fn markBindingLiteBlockScope(
    ast: *const Ast,
    node: ast_mod.Node,
    lite: *BindingLite,
    parent_shadowed: []const []const u8,
) error{OutOfMemory}!void {
    var shadow_buf: [binding_lite_max_shadows][]const u8 = undefined;
    var shadow_len: usize = 0;
    for (parent_shadowed) |name| appendBindingLiteShadowName(&shadow_buf, &shadow_len, name);
    try collectBindingLiteListLexicalShadows(ast, node.data.list, lite, &shadow_buf, &shadow_len);
    try markBindingLiteListValueUses(ast, node.data.list, lite, true, shadow_buf[0..shadow_len]);
}

fn markBindingPatternDefaultValueUses(ast: *const Ast, idx: ast_mod.NodeIndex, lite: *BindingLite, shadowed_names: []const []const u8) error{OutOfMemory}!void {
    if (idx.isNone()) return;
    const node = ast.getNode(idx);
    switch (node.tag) {
        .assignment_pattern,
        .assignment_expression,
        .assignment_target_with_default,
        => {
            try markBindingPatternDefaultValueUses(ast, node.data.binary.left, lite, shadowed_names);
            try markBindingLiteValueUses(ast, node.data.binary.right, lite, true, shadowed_names);
        },
        .array_pattern,
        .object_pattern,
        => try markBindingLiteListValueUses(ast, node.data.list, lite, false, shadowed_names),
        .binding_rest_element,
        .rest_element,
        .assignment_target_rest,
        => try markBindingPatternDefaultValueUses(ast, node.data.unary.operand, lite, shadowed_names),
        .binding_property,
        .assignment_target_property_identifier,
        .assignment_target_property_property,
        => try markBindingPatternDefaultValueUses(ast, node.data.binary.right, lite, shadowed_names),
        else => {},
    }
}

fn markBindingLiteListValueUses(ast: *const Ast, list: ast_mod.NodeList, lite: *BindingLite, value_context: bool, shadowed_names: []const []const u8) error{OutOfMemory}!void {
    if (list.start + list.len > ast.extra_data.items.len) return;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        try markBindingLiteValueUses(ast, @enumFromInt(ast.extra_data.items[list.start + i]), lite, value_context, shadowed_names);
    }
}

fn markBindingLiteFunctionScope(
    ast: *const Ast,
    lite: *BindingLite,
    parent_shadowed: []const []const u8,
    node: ast_mod.Node,
    params_idx: ast_mod.NodeIndex,
    body_idx: ast_mod.NodeIndex,
) error{OutOfMemory}!void {
    var shadow_buf: [binding_lite_max_shadows][]const u8 = undefined;
    var shadow_len: usize = 0;
    for (parent_shadowed) |name| appendBindingLiteShadowName(&shadow_buf, &shadow_len, name);
    collectBindingLiteFunctionExpressionNameShadow(ast, node, lite, &shadow_buf, &shadow_len);
    try collectBindingLitePatternShadows(ast, params_idx, lite, &shadow_buf, &shadow_len);
    try collectBindingLiteFunctionVarShadows(ast, body_idx, lite, &shadow_buf, &shadow_len);
    const combined = shadow_buf[0..shadow_len];
    try markBindingLiteValueUses(ast, params_idx, lite, false, combined);
    try markBindingLiteValueUses(ast, body_idx, lite, true, combined);
}

fn markBindingLiteValueUses(ast: *const Ast, idx: ast_mod.NodeIndex, lite: *BindingLite, value_context: bool, shadowed_names: []const []const u8) error{OutOfMemory}!void {
    // 반복 worklist(#4123): 원본은 generic descent(switch 의 else / value_context=true 인
    // assignment_expression)에서 같은 (value_context, shadowed_names)로 자식을 재귀 → 깊은
    // 좌결합 체인(`+` 등)에서 스택 오버플로우(실측 — named-import + 40000항). switch 본체를
    // markBindingLiteValueUsesNode(special→handled/true, generic→false)로 추출하고 generic
    // 노드만 worklist 로 평탄화한다. special 케이스의 sub-part 재귀(binding pattern/scope/value
    // 식)는 다시 이 wrapper 를 타며, 깊은 value 식은 generic→worklist 로 평탄화되어 얕다.
    // generic descent 동안 (value_context, shadowed_names)는 불변 → 단순 NodeIndex 스택으로 충분.
    const Push = struct {
        fn go(
            a: *const Ast,
            n: ast_mod.Node,
            st: *std.ArrayListUnmanaged(ast_mod.NodeIndex),
            cb: *std.ArrayListUnmanaged(ast_mod.NodeIndex),
        ) error{OutOfMemory}!void {
            try ast_walk.collectChildrenInto(a, n, cb, a.allocator);
            var i = cb.items.len; // 소스 순서 보존: 역순 push → LIFO pop 이 forward
            while (i > 0) {
                i -= 1;
                try st.append(a.allocator, cb.items[i]);
            }
        }
    };

    var stack: std.ArrayListUnmanaged(ast_mod.NodeIndex) = .empty;
    defer stack.deinit(ast.allocator);
    var child_buf: std.ArrayListUnmanaged(ast_mod.NodeIndex) = .empty;
    defer child_buf.deinit(ast.allocator);

    try stack.append(ast.allocator, idx);
    while (stack.pop()) |cur| {
        if (try markBindingLiteValueUsesNode(ast, cur, lite, value_context, shadowed_names)) continue; // special: 자체 처리됨
        // generic 노드: 자식을 같은 (value_context, shadowed_names)로 descend.
        try Push.go(ast, ast.getNode(cur), &stack, &child_buf);
    }
}

/// markBindingLiteValueUses 의 per-node 처리. special 케이스(자체적으로 sub-part 를 적절한
/// value_context 로 재귀)는 true 를, generic(자식을 같은 state 로 내려가야 하는 노드)은 false 를
/// 반환한다. wrapper(markBindingLiteValueUses)가 false 노드의 자식 descent 를 worklist 로 평탄화한다.
fn markBindingLiteValueUsesNode(ast: *const Ast, idx: ast_mod.NodeIndex, lite: *BindingLite, value_context: bool, shadowed_names: []const []const u8) error{OutOfMemory}!bool {
    // children() 는 extra_data 값을 그대로 yield 하므로(범위 검증 안 함) none 외에 out-of-range 도
    // 가능 → getNode 전 bounds 가드(true=처리됨 취급, wrapper 는 자식 push 안 함). scanChildren 동일.
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return true;
    const node = ast.getNode(idx);

    if (Transformer.isTypeOnlyNode(node.tag) or node.tag.isTypeOnlyDeclaration()) return true;

    switch (node.tag) {
        .identifier_reference,
        .assignment_target_identifier,
        => {
            if (value_context) markBindingLiteUse(lite, ast.getText(node.span), shadowed_names);
            return true;
        },
        .binding_identifier,
        .import_declaration,
        .import_specifier,
        .import_default_specifier,
        .import_namespace_specifier,
        .import_attribute,
        => return true,
        .block_statement,
        .function_body,
        => {
            try markBindingLiteBlockScope(ast, node, lite, shadowed_names);
            return true;
        },
        .catch_clause => {
            var shadow_buf: [binding_lite_max_shadows][]const u8 = undefined;
            var shadow_len: usize = 0;
            for (shadowed_names) |name| appendBindingLiteShadowName(&shadow_buf, &shadow_len, name);
            try collectBindingLitePatternShadows(ast, node.data.binary.left, lite, &shadow_buf, &shadow_len);
            try markBindingLiteValueUses(ast, node.data.binary.right, lite, true, shadow_buf[0..shadow_len]);
            return true;
        },
        .try_statement => {
            try markBindingLiteValueUses(ast, node.data.ternary.a, lite, true, shadowed_names);
            try markBindingLiteValueUses(ast, node.data.ternary.b, lite, true, shadowed_names);
            try markBindingLiteValueUses(ast, node.data.ternary.c, lite, true, shadowed_names);
            return true;
        },
        .export_specifier => {
            try markBindingLiteValueUses(ast, node.data.binary.left, lite, true, shadowed_names);
            return true;
        },
        .export_named_declaration => {
            const x = module_parser.readExportNamedExtras(ast, node.data.extra);
            try markBindingLiteValueUses(ast, x.decl, lite, true, shadowed_names);
            try markBindingLiteListValueUses(ast, .{ .start = x.specs_start, .len = x.specs_len }, lite, true, shadowed_names);
            return true;
        },
        .variable_declaration => {
            const list_start = ast.extra_data.items[node.data.extra + 1];
            const list_len = ast.extra_data.items[node.data.extra + 2];
            try markBindingLiteListValueUses(ast, .{ .start = list_start, .len = list_len }, lite, true, shadowed_names);
            return true;
        },
        .variable_declarator => {
            try markBindingPatternDefaultValueUses(ast, @enumFromInt(ast.extra_data.items[node.data.extra]), lite, shadowed_names);
            try markBindingLiteValueUses(ast, @enumFromInt(ast.extra_data.items[node.data.extra + 2]), lite, true, shadowed_names);
            return true;
        },
        .function_declaration,
        .function_expression,
        .function,
        => {
            const e = node.data.extra;
            try markBindingLiteFunctionScope(
                ast,
                lite,
                shadowed_names,
                node,
                @enumFromInt(ast.extra_data.items[e + 1]),
                @enumFromInt(ast.extra_data.items[e + 2]),
            );
            return true;
        },
        .arrow_function_expression => {
            const e = node.data.extra;
            try markBindingLiteFunctionScope(
                ast,
                lite,
                shadowed_names,
                node,
                @enumFromInt(ast.extra_data.items[e]),
                @enumFromInt(ast.extra_data.items[e + 1]),
            );
            return true;
        },
        .formal_parameters => {
            try markBindingLiteListValueUses(ast, node.data.list, lite, false, shadowed_names);
            return true;
        },
        .assignment_pattern,
        .assignment_target_with_default,
        => {
            try markBindingLiteValueUses(ast, node.data.binary.left, lite, false, shadowed_names);
            try markBindingLiteValueUses(ast, node.data.binary.right, lite, true, shadowed_names);
            return true;
        },
        // `(Foo = Bar()) =>` 같이 cover-grammar 로 패턴 자리에 남은 assignment_expression 은
        // value_context=false (formal_parameters 진입) 에서만 LHS=binding/RHS=value 로 쪼갠다.
        // expression context (`Foo = expr;`) 는 LHS 가 assignment_target_identifier 라 default
        // child walk 로 그대로 value_context=true 가 전파돼야 import 가 use 마킹된다(generic descent).
        .assignment_expression => {
            if (!value_context) {
                try markBindingLiteValueUses(ast, node.data.binary.left, lite, false, shadowed_names);
                try markBindingLiteValueUses(ast, node.data.binary.right, lite, true, shadowed_names);
                return true;
            }
        },
        .formal_parameter => {
            const e = node.data.extra;
            try markBindingPatternDefaultValueUses(ast, @enumFromInt(ast.extra_data.items[e]), lite, shadowed_names);
            try markBindingLiteValueUses(ast, @enumFromInt(ast.extra_data.items[e + 2]), lite, true, shadowed_names);
            return true;
        },
        .object_property => {
            const key = node.data.binary.left;
            const value = node.data.binary.right;
            if (value.isNone()) {
                try markBindingLiteValueUses(ast, key, lite, true, shadowed_names);
            } else {
                const key_node = ast.getNode(key);
                if (key_node.tag == .computed_property_key) try markBindingLiteValueUses(ast, key, lite, true, shadowed_names);
                try markBindingLiteValueUses(ast, value, lite, true, shadowed_names);
            }
            return true;
        },
        .static_member_expression,
        .private_field_expression,
        => {
            try markBindingLiteValueUses(ast, @enumFromInt(ast.extra_data.items[node.data.extra]), lite, true, shadowed_names);
            return true;
        },
        else => {},
    }

    // generic 노드(else, 또는 value_context=true 인 assignment_expression): wrapper 가 descend.
    return false;
}

/// Rewrite only identifier tokens in the standalone helper preamble. A byte
/// replacement would also alter strings, comments, or regular expressions.
fn rewriteRuntimeHelperPreamble(
    allocator: std.mem.Allocator,
    transformer: *Transformer,
    preamble: []const u8,
    minify: bool,
    directly_emitted_names: rt.StandaloneRuntimeHelperLocalNames,
) TranspileError![]const u8 {
    var scanner = Scanner.init(allocator, preamble) catch return error.OutOfMemory;
    defer scanner.deinit();

    var output: std.ArrayList(u8) = .empty;
    var copied_until: usize = 0;
    var changed = false;
    scanner.next() catch return error.OutOfMemory;
    while (scanner.token.kind != .eof) {
        const token = scanner.token;
        if (token.kind == .identifier) {
            const start: usize = token.span.start;
            const end: usize = token.span.end;
            const name = preamble[start..end];
            const is_direct_extends = directly_emitted_names.extends != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__extends", minify));
            const is_direct_generator = directly_emitted_names.generator != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__generator", minify));
            const is_direct_rest = directly_emitted_names.rest != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__rest", minify));
            const is_direct_async = directly_emitted_names.async_helper != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__async", minify));
            const is_direct_async_values = directly_emitted_names.async_values != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__asyncValues", minify));
            const is_direct_tagged_template = directly_emitted_names.tagged_template_literal != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__taggedTemplateLiteral", minify));
            const is_direct_read = directly_emitted_names.read != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__read", minify));
            const is_direct_public_field = directly_emitted_names.public_field != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__publicField", minify));
            const is_direct_keep_names = directly_emitted_names.keep_names != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__name", minify));
            const is_direct_tdz = directly_emitted_names.tdz != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__tdz", minify));
            const is_direct_class_call_check = directly_emitted_names.class_call_check != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__classCallCheck", minify));
            const is_direct_class_private_method_init = directly_emitted_names.class_private_method_init != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__classPrivateMethodInit", minify));
            const is_direct_class_private_method_get = directly_emitted_names.class_private_method_get != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__classPrivateMethodGet", minify));
            const is_direct_class_private_field_set = directly_emitted_names.class_private_field_set != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__classPrivateFieldSet", minify));
            const is_direct_call_super = directly_emitted_names.call_super != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__callSuper", minify));
            const is_direct_super_get = directly_emitted_names.super_get != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__superGet", minify));
            const is_direct_super_set = directly_emitted_names.super_set != null and
                std.mem.eql(u8, name, runtime_helper_names.helperName("__superSet", minify));
            if (!is_direct_extends and !is_direct_generator and !is_direct_rest and !is_direct_async and !is_direct_async_values and !is_direct_tagged_template and !is_direct_read and !is_direct_public_field and !is_direct_keep_names and !is_direct_tdz and !is_direct_class_call_check and !is_direct_class_private_method_init and !is_direct_class_private_method_get and !is_direct_class_private_field_set and !is_direct_call_super and !is_direct_super_get and !is_direct_super_set and runtime_helper_names.isRuntimeHelperLocalName(name, minify)) {
                const resolved = es_helpers.resolveRuntimeHelperName(transformer, name) catch return error.OutOfMemory;
                if (!std.mem.eql(u8, name, resolved)) {
                    try output.appendSlice(allocator, preamble[copied_until..start]);
                    try output.appendSlice(allocator, resolved);
                    copied_until = end;
                    changed = true;
                }
            }
        }
        scanner.next() catch return error.OutOfMemory;
    }
    if (!changed) return preamble;
    try output.appendSlice(allocator, preamble[copied_until..]);
    return output.items;
}

/// Resolve the standalone helper's output spelling through the exact semantic
/// helper SymbolId. Name-only fallback remains for low-level transformers
/// without semantic ownership.
fn standaloneRuntimeHelperSymbolName(
    transformer: *Transformer,
    base_name: []const u8,
    minify: bool,
) TranspileError![]const u8 {
    const canonical_name = runtime_helper_names.helperName(base_name, minify);
    const local_name = es_helpers.resolveRuntimeHelperName(transformer, canonical_name) catch return error.OutOfMemory;
    if (!transformer.semantic_edit_enabled or transformer.options.emit_runtime_helper_imports) return local_name;

    const raw_id = transformer.helper_scope_map.get(local_name) orelse return error.TransformError;
    if (raw_id >= transformer.symbols.len) return error.TransformError;
    const symbol = transformer.symbols[raw_id];
    if (symbol.kind != .import_binding or !std.mem.eql(u8, symbol.synthetic_name, local_name))
        return error.TransformError;
    return symbol.synthetic_name;
}

/// 소스 문자열을 트랜스파일한다. I/O 없음, 순수 함수.
///
/// file_path는 확장자 감지용으로만 사용 (실제 파일 읽기 안 함).
/// 반환된 code/sourcemap은 allocator 소유 — caller가 deinit() 해야 함.
pub fn transpile(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    options: TranspileOptions,
) TranspileError!TranspileResult {
    return transpileWithCallback(allocator, source, file_path, options, null);
}

/// 에러 콜백 포함 트랜스파일. 파서/시맨틱 에러 시 콜백을 호출한 뒤 에러를 반환.
pub fn transpileWithCallback(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    options: TranspileOptions,
    on_error: ?ErrorCallback,
) TranspileError!TranspileResult {
    return transpileWithCallbackInternal(
        allocator,
        source,
        file_path,
        options,
        on_error,
        transpileFastPathDisabledByEnv(),
    );
}

/// `.d.ts` / `.d.mts` / `.d.cts` 는 declaration-only 파일 — 모든 runtime 의미가
/// 없는 type-only 컨텐츠라 transpile 결과가 빈 출력. parse/transform/codegen 단계
/// 자체를 skip 하는 게 정확 (tsc/Babel 동작과 일치). D12 의 parser 측 ambient 면제
/// 와 별개로, output 차원에서도 ambient declaration 을 emit 하지 않도록 한다.
fn isDeclarationFile(file_path: []const u8) bool {
    return std.mem.endsWith(u8, file_path, ".d.ts") or
        std.mem.endsWith(u8, file_path, ".d.mts") or
        std.mem.endsWith(u8, file_path, ".d.cts");
}

/// `ZNTC_MEM_PROFILE` 존재 여부 — 프로세스 1회 캐시 (std.once, WASI/Windows 포터블).
/// 직접 std.posix.getenv 는 WASI 에서 @compileError 라 env_flag.Once 사용.
const mem_profile_env = @import("env_flag.zig").Once("ZNTC_MEM_PROFILE");
/// `ZNTC_DEBUG_SYMBOL_COVERAGE` — 트랜스포머 출력의 심볼 ID 누락 측정 (#4760, 디버그 전용).
const symbol_coverage_env = @import("env_flag.zig").Once("ZNTC_DEBUG_SYMBOL_COVERAGE");
const synthetic_coverage_env = @import("env_flag.zig").Once("ZNTC_DEBUG_SYNTHETIC_COVERAGE");

/// transpile phase 별 arena 누적 capacity 스냅샷 (RFC_TRANSFORMER_OWN_AST PR-3 측정).
/// `ZNTC_MEM_PROFILE=1` 일 때만 stderr 로 phase 경계 증분 출력 — 단일 arena 라 phase 별
/// alloc 의 직접 분리는 불가하나, queryCapacity 증분이 각 phase 가 추가한 메모리의 proxy.
/// 평소엔 enabled=false 라 snap() 이 즉시 return (hot path 영향 0).
/// ⚠️ queryCapacity 는 reserved high-water mark — 마지막 arena BufNode 의 미사용 tail 에
/// fit 하는 alloc (clone, codegen output) 은 증분 0 으로 *과소측정*. 실제 phase 비용은
/// peak RSS 로 봐야 한다 (RFC §11.3 참조).
const MemProfile = struct {
    enabled: bool,
    prev: usize = 0,

    fn init() MemProfile {
        return .{ .enabled = mem_profile_env.enabled() };
    }

    fn snap(self: *MemProfile, arena: *std.heap.ArenaAllocator, label: []const u8) void {
        if (!self.enabled) return;
        const cap = arena.queryCapacity();
        const delta = cap -| self.prev;
        const to_mb = struct {
            fn f(b: usize) f64 {
                return @as(f64, @floatFromInt(b)) / (1024.0 * 1024.0);
            }
        }.f;
        std.debug.print(
            "[mem] {s:<10} arena={d:>11} B ({d:>8.1} MB)  Δ +{d:>8.1} MB\n",
            .{ label, cap, to_mb(cap), to_mb(delta) },
        );
        self.prev = cap;
    }
};

fn transpileWithCallbackInternal(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    options: TranspileOptions,
    on_error: ?ErrorCallback,
    fast_path_disabled: bool,
) TranspileError!TranspileResult {
    // `.d.ts` declaration 파일: 전체 type-only → 빈 출력 (D12.5).
    if (isDeclarationFile(file_path)) return .{ .code = try allocator.dupe(u8, "") };

    // 단일 arena (RFC_TRANSFORMER_OWN_AST PR-2 후): clone 회피로 parser.ast 가 transformer.ast
    // 와 동일 instance — 이른 deinit 으로 회수할 영역 자체가 없어 PR #3941 의 parser_arena/
    // transformer_arena 2-arena 구조는 의미 없음. 단일 arena 로 환원.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var mem_profile = MemProfile.init();
    mem_profile.snap(&arena, "start");

    // 1. 파싱
    var scanner = Scanner.init(arena_alloc, source) catch return error.OutOfMemory;

    // --stop-after=scan: 파서 호출 없이 토큰 drain 만 수행 (profile/debug 용).
    // Scanner 가 lazy 이므로 next() 로 EOF 까지 소비해야 실제 tokenization 비용이 발생.
    if (options.stop_after == .scan) {
        scanner.next() catch return error.ParseError;
        while (scanner.token.kind != .eof) {
            scanner.next() catch return error.ParseError;
        }
        return .{ .code = try allocator.dupe(u8, "") };
    }

    var parser = Parser.init(arena_alloc, &scanner);
    parser.configureFromExtension(std.fs.path.extension(file_path));
    parser.configureAmbientFromPath(file_path);

    if (parser.source_mode != .ts) {
        if (options.flow) {
            parser.is_flow = true;
            scanner.has_flow_pragma = true;
            if (!parser.is_module) {
                parser.is_module = true;
                scanner.is_module = true;
                parser.is_unambiguous = true;
            }
        } else {
            parser.configureFlowFromPath(file_path);
        }
    }
    if (options.jsx_in_js and parser.source_mode != .ts) {
        parser.is_jsx = true;
    }
    const source_root = parser.parse() catch return error.ParseError;
    mem_profile.snap(&arena, "parse");
    // Ast 가 arena 안에 살아 Ast.deinit() 가 호출되지 않으므로, intern stats dump 를
    // arena 해제 직전(LIFO) 에 명시 호출. ZNTC_STRING_INTERN_STATS=1 일 때만 출력.
    defer parser.ast.dumpStringInternStatsIfEnabled();
    if (parser.errors.items.len > 0) {
        if (on_error) |cb| cb(source, file_path, &scanner, parser.errors.items);
        return error.ParseError;
    }

    if (options.stop_after == .parse) {
        return .{ .code = try allocator.dupe(u8, "") };
    }

    const transform_plan = try buildTransformPlan(options, &parser, &parser.ast, fast_path_disabled);
    // 포맷 문자열을 변경하면 `tests/benchmark/profile.ts` 의 `tracePlan` 정규식도
    // 함께 갱신해야 한다 — `semantic=...`, `reason=...` 키 이름을 그대로 유지.
    debug_log.print(
        .transform_plan,
        "file={s} semantic={s} reason={s} strip_types_only={}\n",
        .{ file_path, @tagName(transform_plan.semantic), @tagName(transform_plan.reason), transform_plan.strip_types_only },
    );

    // 2. Semantic analysis
    // TS 모듈에서 `type X = ...; export { X };` 같은 패턴을 자동 type-only export 로
    // elision (Babel preset-typescript 동작). analyzer 진입 전 pre-pass 로 SPEC_FLAG_TYPE_ONLY
    // 비트를 마킹 → transformer 의 `.export_specifier` 디스패치가 자동 drop. .full /
    // .bindings / .none 모든 경로에서 동일 비트 기반.
    //
    // Flow 는 별도 type system 이라 제외 (flow_ 태그 처리는 별도 영역). non-TS 입력은
    // type alias 자체가 없어 helper 가 early return.
    if (parser.source_mode == .ts and !parser.is_flow) {
        try ts_auto_export.markAutoTypeOnlyExportSpecifiers(arena_alloc, &parser.ast, null);
    }

    var analyzer_storage: ?SemanticAnalyzer = null;
    var binding_lite_storage: ?BindingLite = null;
    if (transform_plan.semantic == .full) {
        analyzer_storage = SemanticAnalyzer.init(arena_alloc, &parser.ast);
        var analyzer = &analyzer_storage.?;
        analyzer.is_strict_mode = parser.is_strict_mode;
        analyzer.is_module = parser.is_module;
        analyzer.is_ts = parser.source_mode == .ts;
        analyzer.is_flow = parser.is_flow;
        analyzer.es_target = options.es_target;
        analyzer.unsupported = options.unsupported;
        analyzer.collect_unresolved_reference_nodes = symbol_coverage_env.enabled();
        analyzer.analyze() catch return error.SemanticError;
        // tsc 호환: 시맨틱 에러가 있어도 codegen 을 진행한다 — 콜백으로 stderr 통지 후
        // 변환 결과도 함께 반환.
        if (analyzer.errors.items.len > 0) {
            if (on_error) |cb| cb(source, file_path, &scanner, analyzer.errors.items);
        }
    } else if (transform_plan.semantic == .bindings) {
        binding_lite_storage = try collectBindingLite(arena_alloc, &parser.ast);
    }
    mem_profile.snap(&arena, "semantic");

    if (options.stop_after == .semantic) {
        return .{ .code = try allocator.dupe(u8, "") };
    }

    // 3. Identifier mangling (--minify-identifiers) 은 변환 **뒤**에 한다 (아래 4.5).
    var mangle_result: ?Mangler.ManglerResult = null;
    defer if (mangle_result) |*mr| mr.deinit();

    // 4. 변환
    const transform_opts: TransformOptions = .{
        .drop_console = options.drop_console,
        .drop_debugger = options.drop_debugger,
        .define = options.define,
        .use_define_for_class_fields = options.use_define_for_class_fields,
        .experimental_decorators = options.experimental_decorators,
        .emit_decorator_metadata = options.emit_decorator_metadata,
        .verbatim_module_syntax = options.verbatim_module_syntax,
        .unsupported = options.unsupported,
        // JSX lowering: JSX가 있는 모듈에서만 활성화
        .jsx_transform = parser.ast.has_jsx,
        // standalone JSX import 도 AST binding 으로 만들어 semantic edit 에 연결한다.
        .emit_jsx_runtime_imports = parser.ast.has_jsx,
        .jsx_runtime = options.jsx_runtime,
        .jsx_factory = options.jsx_factory,
        .jsx_fragment = options.jsx_fragment,
        .jsx_import_source = options.jsx_import_source,
        .jsx_filename = file_path,
        // #1621: standalone transpile 경로도 minify 시 runtime helper 축약 이름 사용.
        .minify_whitespace = options.minify_whitespace,
        .react_refresh = options.react_refresh,
        .react_refresh_hook_signatures = options.react_refresh_hook_signatures,
    };
    // per-file JSX pragma (D026): tsconfig/CLI 보다 우선 — graph pre-pass 와 동일 경로.
    const effective_opts = transform_opts.withModuleJsxPragmas(&parser.ast);
    if (effective_opts.jsxClassicPragmaIgnoredUnderAutomatic(&parser.ast)) {
        std.log.warn("zntc: {s}: {s}", .{ file_path, TransformOptions.jsx_pragma_ignored_msg });
    }
    // RFC_TRANSFORMER_OWN_AST PR-2: clone 회피 — transformer 가 parser.ast 의 ownership 을
    // 양도받아 *동일 instance* 를 직접 mutate. cloneForTransformer 의 deep copy 회피로
    // 87MB synthetic 기준 peak RSS -84 MB (-2.6%, n=30 p<0.0001) 절감 (clone 배열이
    // 이미 pre-warm 된 상태라 RFC 초기 추정 -580 MB 보다 작음). transpile path 전용 —
    // bundler 의 graph cache / HMR re-process 는 원본 보존 의무라 init 유지.
    // 위 `defer parser.ast.dumpStringInternStatsIfEnabled()` 가 stats 를 dump 하므로
    // 여기서 별도 defer 불필요 — parser.ast 와 transformer.ast 가 같은 instance.
    const pre_transform_scope_count = if (analyzer_storage) |*analyzer| analyzer.scopes.items.len else 0;
    var transformer = try Transformer.initFromOwnedAst(arena_alloc, &parser.ast, effective_opts);
    if (analyzer_storage) |*analyzer| {
        transformer.initSymbolIds(analyzer.symbol_ids.items) catch return error.TransformError;
        transformer.symbols = analyzer.symbols.items;
        transformer.references = analyzer.references.items;
        transformer.scopes = analyzer.scopes.items;
        transformer.scope_maps = analyzer.scope_maps.items;
        transformer.scope_owner_map = analyzer.scope_owner_map;
        transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
        transformer.helper_scope_map = analyzer.helper_scope_map;
        transformer.namespace_member_owners = &analyzer.namespace_member_owners;
        transformer.namespace_declaration_owners = &analyzer.namespace_declaration_owners;
        transformer.semantic_edit_enabled = true;
        transformer.unresolved_references = &analyzer.unresolved_references;
    } else if (binding_lite_storage) |*binding_lite| {
        transformer.binding_lite = binding_lite;
    }
    transformer.line_offsets = scanner.line_offsets.items;
    // 누락 검사기가 합성 노드를 빼도록 기록을 켠다(검사기가 켜졌을 때만 — 평소 비용 없음).
    if (symbol_coverage_env.enabled() or synthetic_coverage_env.enabled()) transformer.synthetic_idents = .empty;
    if (symbol_coverage_env.enabled()) {
        if (analyzer_storage) |*analyzer| transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    }
    if (symbol_coverage_env.enabled()) {
        if (analyzer_storage) |*analyzer| {
            const coverage = @import("transformer/symbol_coverage.zig");
            const source_scope_owner_audit = coverage.checkExact(
                arena_alloc,
                transformer.ast,
                source_root,
                transformer.parser_node_count,
                analyzer.symbol_ids.items,
                analyzer.symbols.items,
                analyzer.scopes.items,
                analyzer.scope_maps.items,
                &analyzer.scope_owner_map,
                analyzer.references.items,
                transformer.helper_ref_nodes.items,
                &analyzer.helper_scope_map,
                &analyzer.unresolved_reference_nodes,
                &transformer.explicit_global_reference_nodes,
                &transformer.reference_origin_map,
            ) catch return error.OutOfMemory;
            coverage.printSourceScopeOwnerAudit(file_path, source_scope_owner_audit);
        }
    }
    const root = transformer.transform() catch return error.TransformError;
    if (analyzer_storage) |*analyzer| {
        if (transformer.finishSemanticEdit() catch return error.TransformError) |edited| {
            analyzer.applyEdit(edited);
            transformer.symbols = analyzer.symbols.items;
            transformer.references = analyzer.references.items;
            transformer.scopes = analyzer.scopes.items;
            transformer.scope_maps = analyzer.scope_maps.items;
            transformer.scope_owner_map = analyzer.scope_owner_map;
            transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
            transformer.helper_scope_map = analyzer.helper_scope_map;
        }
    }
    mem_profile.snap(&arena, "transform");

    // #4760: 트랜스포머가 새로 만든 사용자 식별자 노드의 심볼 ID 누락 측정(디버그 전용).
    if (symbol_coverage_env.enabled()) {
        if (analyzer_storage) |*analyzer| {
            const coverage = @import("transformer/symbol_coverage.zig");
            var report = coverage.check(arena_alloc, transformer.ast, root, transformer.parser_node_count, transformer.symbol_ids.items, analyzer.symbols.items, if (transformer.synthetic_idents) |*s| s else null) catch return error.OutOfMemory;
            coverage.print(arena_alloc, file_path, &report);
            const exact = coverage.checkExactWithNamespaceMetadata(
                arena_alloc,
                transformer.ast,
                root,
                transformer.parser_node_count,
                analyzer.symbol_ids.items,
                analyzer.symbols.items,
                analyzer.scopes.items,
                analyzer.scope_maps.items,
                &analyzer.scope_owner_map,
                analyzer.references.items,
                transformer.helper_ref_nodes.items,
                &analyzer.helper_scope_map,
                &analyzer.unresolved_reference_nodes,
                &transformer.explicit_global_reference_nodes,
                &transformer.reference_origin_map,
                &analyzer.namespace_member_owners,
                &analyzer.namespace_declaration_owners,
                pre_transform_scope_count,
            ) catch return error.OutOfMemory;
            coverage.printExact(file_path, exact);
        }
    }
    if (synthetic_coverage_env.enabled()) {
        if (analyzer_storage) |*analyzer| {
            const coverage = @import("transformer/symbol_coverage.zig");
            var report = coverage.checkStrictWithExactExternalEvidence(
                arena_alloc,
                transformer.ast,
                root,
                transformer.parser_node_count,
                transformer.symbol_ids.items,
                analyzer.symbols.items,
                analyzer.scopes.items,
                &analyzer.scope_owner_map,
                analyzer.references.items,
                if (transformer.synthetic_idents) |*s| s else null,
                .{
                    .unresolved_reference_nodes = &analyzer.unresolved_reference_nodes,
                    .explicit_global_reference_nodes = &transformer.explicit_global_reference_nodes,
                    .reference_origin_map = &transformer.reference_origin_map,
                },
            ) catch return error.OutOfMemory;
            coverage.printStrict(file_path, &report);
        }
    }

    // #4210: 다운레벨 못한 ES2025 inline modifier 그룹이 출력에 보존됨 → loud 진단
    // (transform-driven — 실제 fold bail 을 정확 반영, graph pre-pass 와 동일 메시지).
    if (transformer.used_unsupported_modifier) {
        std.log.warn("zntc: {s}: {s}", .{ file_path, TransformOptions.regex_modifier_unsupported_msg });
    }

    if (options.stop_after == .transform) {
        return .{ .code = try allocator.dupe(u8, "") };
    }

    if (options.minify_syntax) {
        const analyzer = &(analyzer_storage.?);
        const minify_mod = @import("transformer/minify.zig");
        const ctx: minify_mod.MinifyCtx = .{
            .symbols = analyzer.symbols.items,
            .symbol_ids = transformer.symbol_ids.items,
            // 동일 backing 의 mutable view — codegen/mangler 도 `transformer.symbol_ids` 를
            // 읽으므로(mangle_metadata.symbol_ids) alias inline 의 symbol_id 갱신이 전파됨.
            .symbol_ids_mut = transformer.symbol_ids.items,
            .scopes = analyzer.scopes.items,
            .unresolved_globals = null,
            .references = analyzer.references.items,
            .allow_top_level_inline = options.minify_syntax,
        };
        minify_mod.minify(transformer.ast, ctx, arena_alloc, root);
        // S4b: 단일 파일 모드에서도 const → let 변환 후 mergeDecls — esbuild parity.
        if (options.minify_syntax) minify_mod.convertConstToLet(transformer.ast);
        minify_mod.mergeDecls(transformer.ast, root, null, arena_alloc);
    }

    // 4.5. 이름 줄이기는 보통 **낮춘 뒤의 코드**를 다시 분석해서 한다 (#4759·#4760).
    // 상태 기계·`_loop` 은 변수를 다른 함수로 옮기고 새 이름을 만든다. native JS
    // script 는 visitor 가 AST 노드를 복제하더라도 어휘 그래프가 그대로이므로
    // 편집된 변환 의미 정보를 쓴다. AST 길이만으로 이 조건을 판정할 수 없다.
    var post_analyzer_storage: ?SemanticAnalyzer = null;
    var mangle_analyzer: ?*SemanticAnalyzer = null;
    var mangle_uses_transform_semantic = false;
    if (options.minify_identifiers and analyzer_storage != null) {
        if (canMangleWithTransformSemantic(options, &parser)) {
            mangle_uses_transform_semantic = true;
            mangle_analyzer = &analyzer_storage.?;
        } else {
            post_analyzer_storage = SemanticAnalyzer.init(arena_alloc, transformer.ast);
            const post = &post_analyzer_storage.?;
            post.is_strict_mode = parser.is_strict_mode;
            post.is_module = parser.is_module;
            // 타입은 이미 지워졌다. 낮춘 코드의 분석 에러(낮추기가 만든 형태)는 이름 짓기와 무관하다.
            post.analyze() catch return error.SemanticError;
            mangle_analyzer = post;
        }
        const post = mangle_analyzer.?;
        if (post.symbols.items.len > 0 and post.scope_maps.items.len > 0) {
            // 변환 전 분석이 "이름 보존"으로 본 심볼(export·import·클래스 식 이름)을
            // mangler graph 로 옮긴다. 재분석 경로에서는 변환이 그 흔적을 지우기도 한다 —
            // TS `export = Box` 는 `module.exports = Box` 가 되어 재분석에선 export 가 아니다.
            // 같은 노드에 변환 전 심볼(트랜스포머가 물려준 것)과 mangler 심볼이 붙으면 짝이다.
            // 보존 이름은 다른 바인딩이 같은 이름을 받지 않게 예약도 한다.
            const pre = &(analyzer_storage.?);
            var keep = std.DynamicBitSet.initEmpty(arena_alloc, post.symbols.items.len) catch return error.OutOfMemory;
            var reserved: std.StringHashMapUnmanaged(void) = .empty;
            var unresolved_it = post.unresolved_references.keyIterator();
            while (unresolved_it.next()) |k| reserved.put(arena_alloc, k.*, {}) catch return error.OutOfMemory;
            if (options.module_format == .cjs) {
                reserveCommonJsCodegenNames(arena_alloc, &reserved) catch return error.OutOfMemory;
            }
            reserveFlowEnumCodegenNames(arena_alloc, transformer.ast, &reserved) catch return error.OutOfMemory;
            if (mangle_uses_transform_semantic) {
                reserveGeneratedExternalNames(
                    arena_alloc,
                    &reserved,
                    transformer.ast,
                    root,
                    transformer.symbol_ids.items,
                    &transformer.explicit_global_reference_nodes,
                ) catch return error.OutOfMemory;
            }
            for (post.symbol_ids.items, 0..) |maybe_post_sym, node_i| {
                const post_sym = maybe_post_sym orelse continue;
                if (node_i >= transformer.symbol_ids.items.len) continue;
                const pre_sym = transformer.symbol_ids.items[node_i] orelse continue;
                if (pre_sym >= pre.symbols.items.len or post_sym >= post.symbols.items.len) continue;
                if (!Mangler.preservesName(pre.symbols.items[pre_sym])) continue;
                if (keep.isSet(post_sym)) continue;
                keep.set(post_sym);
                reserved.put(arena_alloc, transformer.ast.getText(post.symbols.items[post_sym].name), {}) catch return error.OutOfMemory;
            }
            mangle_result = Mangler.mangle(arena_alloc, .{
                .scopes = post.scopes.items,
                .symbols = post.symbols.items,
                .scope_maps = post.scope_maps.items,
                .references = post.references.items,
                .source = source,
                .ast = transformer.ast,
                // 코드가 참조하는 전역(`Set`, `Map` …)을 예약한다. 없으면 바인딩이 많아 3글자
                // 이름까지 가면 `var Set = …` 처럼 전역을 가린다. 번들 경로는
                // `Linker.collectReservedGlobals` 가 같은 일을 한다.
                .external_reserved = &reserved,
                .skip_symbols = keep,
            }) catch null;
        }
    }

    // Syntax minification mutates the AST; identifier minification builds the
    // final SymbolId-to-name map. Audit after both decisions so syntax-only,
    // identifier-only, and combined minification all pass through this gate.
    if (symbol_coverage_env.enabled() and (options.minify_syntax or options.minify_identifiers)) {
        const source_analyzer = &(analyzer_storage.?);
        const post_minify_coverage = @import("transformer/symbol_coverage.zig");
        var post_minify_analyzer = SemanticAnalyzer.init(arena_alloc, transformer.ast);
        post_minify_analyzer.is_strict_mode = parser.is_strict_mode;
        post_minify_analyzer.is_module = parser.is_module;
        post_minify_analyzer.analyze() catch return error.SemanticError;
        const post_minify_report = try post_minify_coverage.checkPostMinify(
            arena_alloc,
            transformer.ast,
            root,
            transformer.symbol_ids.items,
            post_minify_analyzer.symbol_ids.items,
            source_analyzer.symbols.items,
            post_minify_analyzer.symbols.items,
            source_analyzer.references.items,
            transformer.helper_ref_nodes.items,
            &source_analyzer.helper_scope_map,
            &transformer.explicit_global_reference_nodes,
            &transformer.class_self_symbol_map,
            &post_minify_analyzer.class_self_symbol_map,
        );
        post_minify_coverage.printPostMinify(file_path, post_minify_report);
    }

    // 5. Mangling 메타데이터 구성. skip_nodes는 arena-owned이라 별도 deinit 불필요
    // (함수 종료 시 arena.deinit으로 일괄 해제).
    var mangle_metadata: ?LinkingMetadata = null;

    if (mangle_result) |*mr| {
        const node_count = transformer.ast.nodes.items.len;
        mangle_metadata = .{
            .skip_nodes = std.DynamicBitSet.initEmpty(arena_alloc, node_count) catch return error.OutOfMemory,
            // mr.renames 는 이제 unmanaged map. LinkingMetadata.renames 도 unmanaged 라
            // backing handle 을 그대로 빌린다. 소유권은 mr 에 남아 mr.deinit()
            // 이 해제 — mangle_metadata 는 deinit 되지 않으므로 double-free 없음.
            .renames = mr.renames,
            .final_exports = null,
            // 이름 표와 노드→심볼은 같은 semantic graph를 사용한다.
            // Minify can replace a parent node with an identifier child. In the
            // transform-graph path it transfers that child's ID into the surviving
            // AST slot, so codegen must consult the same updated node-to-symbol map.
            // The post-transform reanalysis path instead owns its own complete map.
            .symbol_ids = if (mangle_uses_transform_semantic)
                transformer.symbol_ids.items
            else
                mangle_analyzer.?.symbol_ids.items,
            // 단일 파일 transpile: codegen 의 scope-hoisted 전용 분기를 타지 않도록 false.
            .is_bundle_context = false,
            .allocator = arena_alloc,
        };
    }

    // 6. 코드 생성
    // Without identifier mangling, the semantic editor's applied result is the
    // authoritative node->SymbolId map. Syntax minification mutates the
    // transformer's live map later, so keep using that view in that case.
    const codegen_symbol_ids = if (mangle_metadata == null and !options.minify_syntax) blk: {
        if (analyzer_storage) |*analyzer| break :blk analyzer.symbol_ids.items;
        break :blk transformer.symbol_ids.items;
    } else transformer.symbol_ids.items;
    const has_helpers = transformer.runtime_helpers.hasAny();
    const helper_preamble = if (has_helpers) blk: {
        var buf: std.ArrayList(u8) = .empty;
        var local_names: rt.StandaloneRuntimeHelperLocalNames = .{};
        if (transformer.runtime_helpers.extends)
            local_names.extends = try standaloneRuntimeHelperSymbolName(&transformer, "__extends", options.minify_whitespace);
        if (transformer.runtime_helpers.generator)
            local_names.generator = try standaloneRuntimeHelperSymbolName(&transformer, "__generator", options.minify_whitespace);
        if (transformer.runtime_helpers.rest)
            local_names.rest = try standaloneRuntimeHelperSymbolName(&transformer, "__rest", options.minify_whitespace);
        if (transformer.runtime_helpers.class_call_check)
            local_names.class_call_check = try standaloneRuntimeHelperSymbolName(&transformer, "__classCallCheck", options.minify_whitespace);
        if (transformer.runtime_helpers.class_private_method_init)
            local_names.class_private_method_init = try standaloneRuntimeHelperSymbolName(&transformer, "__classPrivateMethodInit", options.minify_whitespace);
        if (transformer.runtime_helpers.class_private_method_get)
            local_names.class_private_method_get = try standaloneRuntimeHelperSymbolName(&transformer, "__classPrivateMethodGet", options.minify_whitespace);
        if (transformer.runtime_helpers.class_private_field_set)
            local_names.class_private_field_set = try standaloneRuntimeHelperSymbolName(&transformer, "__classPrivateFieldSet", options.minify_whitespace);
        if (transformer.runtime_helpers.call_super)
            local_names.call_super = try standaloneRuntimeHelperSymbolName(&transformer, "__callSuper", options.minify_whitespace);
        if (transformer.runtime_helpers.super_get)
            local_names.super_get = try standaloneRuntimeHelperSymbolName(&transformer, "__superGet", options.minify_whitespace);
        if (transformer.runtime_helpers.super_set)
            local_names.super_set = try standaloneRuntimeHelperSymbolName(&transformer, "__superSet", options.minify_whitespace);
        if (transformer.runtime_helpers.async_helper)
            local_names.async_helper = try standaloneRuntimeHelperSymbolName(&transformer, "__async", options.minify_whitespace);
        if (transformer.runtime_helpers.async_values)
            local_names.async_values = try standaloneRuntimeHelperSymbolName(&transformer, "__asyncValues", options.minify_whitespace);
        if (transformer.runtime_helpers.values)
            local_names.values = try standaloneRuntimeHelperSymbolName(&transformer, "__values", options.minify_whitespace);
        if (transformer.runtime_helpers.read)
            local_names.read = try standaloneRuntimeHelperSymbolName(&transformer, "__read", options.minify_whitespace);
        if (transformer.runtime_helpers.public_field)
            local_names.public_field = try standaloneRuntimeHelperSymbolName(&transformer, "__publicField", options.minify_whitespace);
        if (transformer.runtime_helpers.keep_names)
            local_names.keep_names = try standaloneRuntimeHelperSymbolName(&transformer, "__name", options.minify_whitespace);
        if (transformer.runtime_helpers.tdz)
            local_names.tdz = try standaloneRuntimeHelperSymbolName(&transformer, "__tdz", options.minify_whitespace);
        if (transformer.runtime_helpers.tagged_template_literal)
            local_names.tagged_template_literal = try standaloneRuntimeHelperSymbolName(&transformer, "__taggedTemplateLiteral", options.minify_whitespace);
        rt.appendRuntimeHelpersWithStandaloneLocalNames(
            &buf,
            arena_alloc,
            transformer.runtime_helpers,
            options.minify_whitespace,
            transformer.runtime_es5_compat,
            local_names,
        ) catch
            return error.OutOfMemory;
        break :blk try rewriteRuntimeHelperPreamble(
            arena_alloc,
            &transformer,
            buf.items,
            options.minify_whitespace,
            local_names,
        );
    } else "";
    var cg = Codegen.initWithOptions(arena_alloc, transformer.ast, .{
        .module_format = options.module_format,
        .program_preamble = helper_preamble,
        .minify_whitespace = options.minify_whitespace,
        .minify_syntax = options.minify_syntax,
        .sourcemap = options.sourcemap,
        .ascii_only = if (options.charset_utf8) false else options.ascii_only,
        .lower_unicode_brace = options.unsupported.unicode_brace_escape,
        .quote_style = options.quote_style,
        .linking_metadata = if (mangle_metadata) |*mm| mm else null,
        .semantic_symbol_ids = codegen_symbol_ids,
        .semantic_symbols = if (mangle_metadata != null) mangle_analyzer.?.symbols.items else if (analyzer_storage) |*analyzer| analyzer.symbols.items else &.{},
        .semantic_scope_maps = if (mangle_metadata != null) mangle_analyzer.?.scope_maps.items else if (analyzer_storage) |*analyzer| analyzer.scope_maps.items else &.{},
        .generated_iife_scope_owner_map = if (mangle_metadata != null) &mangle_analyzer.?.scope_owner_map else if (analyzer_storage) |*analyzer| &analyzer.scope_owner_map else null,
        .namespace_declaration_owners = if (mangle_metadata != null) &mangle_analyzer.?.namespace_declaration_owners else if (analyzer_storage) |*analyzer| &analyzer.namespace_declaration_owners else null,
        .destructuring_temp_bindings = &transformer.destructuring_temp_bindings,
        .platform = options.platform,
        .source_root = options.source_root,
        .sources_content = options.sources_content,
        .assert_no_raw_private_syntax = options.unsupported.requiresPrivateDownlevel(),
        // JSX: Transformer가 이미 call_expression으로 lowering 완료. codegen에 JSX 옵션 불필요.
    });
    cg.comments = scanner.comments.items;
    if (options.sourcemap) {
        cg.addSourceFile(file_path) catch {};
        cg.line_offsets = scanner.line_offsets.items;
    }
    const output = cg.generate(root) catch return error.CodegenError;
    mem_profile.snap(&arena, "generate");

    // JSX runtime import 는 위 transformer finalize 단계에서 semantic ID 가 붙은 AST 노드로 생성.

    // Runtime helpers are emitted through codegen after directives/hashbang,
    // before user statements, so strict mode and generated source positions agree.

    // 8. Sentry Debug ID (UUID v4) — sourcemap_debug_ids 활성화 시 생성
    var debug_id_buf: [36]u8 = undefined;
    const debug_id: ?[]const u8 = if (options.sourcemap_debug_ids) blk: {
        // 결정론적 debugId — 입력 source 해시 기반 (reproducible build, io 불필요).
        SourceMap.generateUuidV4(&debug_id_buf, source);
        break :blk &debug_id_buf;
    } else null;

    // 9. 소스맵 생성. map.file 필드는 출력 파일명을 가리켜야 함 (Source Map Rev3
    // spec — source path 가 아닌 *생성된* 파일). caller 가 sourcemap_output_filename
    // 을 알려주면 그 값을, 아니면 빈 문자열 (spec 상 optional 필드 — invalid 한
    // source path 보다 안전. CLI 는 main.zig 에서 자동 set, library/NAPI 호출자는
    // 직접 전달 권장). #2217.
    const map_file_name: []const u8 = options.sourcemap_output_filename;
    var sourcemap_json: ?[]const u8 = null;
    if (options.sourcemap) {
        if (cg.sm_builder) |*sm| {
            sm.debug_id = debug_id;
            if (sm.generateJSON(map_file_name) catch null) |sm_json| {
                sourcemap_json = allocator.dupe(u8, sm_json) catch null;
            }
        }
    }

    // 10. footer 부착: sourceMappingURL (#2217) + debugId.
    // sourcemap_output_filename 이 있으면 `//# sourceMappingURL=<file>.map` 도 emit.
    // debugId 와 함께 부착하면 Sentry/DevTools 가 둘 다 인식.
    const need_sm_footer = options.sourcemap and
        sourcemap_json != null and
        options.sourcemap_output_filename.len > 0;
    const final_output = if (debug_id != null or need_sm_footer) blk: {
        var buf: std.ArrayList(u8) = .empty;
        buf.appendSlice(arena_alloc, output) catch break :blk output;
        if (output.len > 0 and output[output.len - 1] != '\n') {
            buf.append(arena_alloc, '\n') catch break :blk output;
        }
        if (need_sm_footer) {
            buf.appendSlice(arena_alloc, "//# sourceMappingURL=") catch break :blk output;
            buf.appendSlice(arena_alloc, options.sourcemap_output_filename) catch break :blk output;
            buf.appendSlice(arena_alloc, ".map\n") catch break :blk output;
        }
        if (debug_id) |did| {
            buf.appendSlice(arena_alloc, "//# debugId=") catch break :blk output;
            buf.appendSlice(arena_alloc, did) catch break :blk output;
            buf.append(arena_alloc, '\n') catch break :blk output;
        }
        break :blk buf.items;
    } else output;
    // emit = generate 이후 jsx/css/runtime-helper prepend + sourcemap footer 까지 포함.
    mem_profile.snap(&arena, "emit");

    // Arena 밖으로 복제 (arena는 함수 종료 시 defer로 해제 — line 167).
    // mangle_metadata.skip_nodes는 arena-owned이므로 별도 deinit 불필요.
    const result_code = allocator.dupe(u8, final_output) catch return error.OutOfMemory;
    errdefer allocator.free(result_code);

    // 시맨틱 에러 복사: arena → allocator. 실패 시 이미 복사된 항목들 roll back.
    const semantic_errors: []const Diagnostic = if (analyzer_storage) |*analyzer|
        analyzer.errors.items
    else
        &.{};
    const owned_diagnostics: []const OwnedDiagnostic = if (semantic_errors.len == 0) &.{} else blk: {
        const buf = allocator.alloc(OwnedDiagnostic, semantic_errors.len) catch return error.OutOfMemory;
        var filled: usize = 0;
        errdefer {
            for (buf[0..filled]) |d| d.deinit(allocator);
            allocator.free(buf);
        }
        for (semantic_errors) |d| {
            buf[filled] = try OwnedDiagnostic.init(d, allocator);
            filled += 1;
        }
        break :blk buf;
    };
    errdefer {
        for (owned_diagnostics) |d| d.deinit(allocator);
        if (owned_diagnostics.len > 0) allocator.free(owned_diagnostics);
    }

    // line_offsets도 복사 (diagnostics 렌더링용). 에러 없으면 생략.
    const owned_line_offsets: []const u32 = if (semantic_errors.len == 0)
        &.{}
    else
        allocator.dupe(u32, scanner.line_offsets.items) catch return error.OutOfMemory;

    return .{
        .code = result_code,
        .sourcemap = sourcemap_json,
        .has_helpers = has_helpers,
        .diagnostics = owned_diagnostics,
        .line_offsets = owned_line_offsets,
    };
}

fn testTransformPlan(source: []const u8, file_path: []const u8, options: TranspileOptions) !TransformPlan {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(std.fs.path.extension(file_path));
    parser.configureAmbientFromPath(file_path);
    if (parser.source_mode != .ts) {
        if (options.flow) {
            parser.is_flow = true;
            scanner.has_flow_pragma = true;
            if (!parser.is_module) {
                parser.is_module = true;
                scanner.is_module = true;
                parser.is_unambiguous = true;
            }
        } else {
            parser.configureFlowFromPath(file_path);
        }
    }
    if (options.jsx_in_js and parser.source_mode != .ts) {
        parser.is_jsx = true;
    }
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    return buildTransformPlan(options, &parser, &parser.ast, false);
}

test "#4819 downlevel JS script mangling reuses transform semantic graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "function read(argument) { const local = argument + 1; return local; }");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".cjs");
    _ = try parser.parse();
    try std.testing.expect(!parser.is_module);
    const minify: TranspileOptions = .{ .minify_identifiers = true };
    try std.testing.expect(canMangleWithTransformSemantic(minify, &parser));
    try std.testing.expect(canMangleWithTransformSemantic(.{
        .minify_identifiers = true,
        .module_format = .cjs,
    }, &parser));
    try std.testing.expect(canMangleWithTransformSemantic(.{ .minify_identifiers = true, .minify_syntax = true }, &parser));
    try std.testing.expect(canMangleWithTransformSemantic(.{ .minify_identifiers = true, .unsupported = TransformOptions.compat.fromESTarget(.es5) }, &parser));
    try std.testing.expect(canMangleWithTransformSemantic(.{ .minify_identifiers = true, .drop_console = true }, &parser));
    try std.testing.expect(canMangleWithTransformSemantic(.{
        .minify_identifiers = true,
        .define = &.{.{ .key = "__VALUE__", .value = "e" }},
    }, &parser));
    try std.testing.expect(canMangleWithTransformSemantic(.{
        .minify_identifiers = true,
        .use_define_for_class_fields = false,
    }, &parser));
    parser.is_module = true;
    try std.testing.expect(canMangleWithTransformSemantic(minify, &parser));
    parser.is_module = false;
    parser.ast.has_jsx = true;
    try std.testing.expect(canMangleWithTransformSemantic(minify, &parser));
}

test "#4819 class lowering reuses transform semantic graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "class Box extends Base { read() { return super.read(); } }");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".cjs");
    _ = try parser.parse();
    try std.testing.expect(!parser.is_module);
    try std.testing.expect(canMangleWithTransformSemantic(.{
        .minify_identifiers = true,
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    }, &parser));
}

test "#4819 React Refresh output reuses transform semantic graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(
        allocator,
        "function App() { const value = useState(1); return value; }",
    );
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".tsx");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    try std.testing.expect(canMangleWithTransformSemantic(.{
        .minify_identifiers = true,
        .react_refresh = true,
    }, &parser));
    try std.testing.expect(canMangleWithTransformSemantic(.{
        .minify_identifiers = true,
        .react_refresh = true,
        .react_refresh_hook_signatures = true,
    }, &parser));
}

test "#4819 type-erased TypeScript reuses transform semantic graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "type Alias = number; interface Shape { amount: Alias } const value: Alias = 1;");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    const minify: TranspileOptions = .{ .minify_identifiers = true };
    try std.testing.expect(canMangleWithTransformSemantic(minify, &parser));

    var namespace_scanner = try Scanner.init(
        allocator,
        "namespace N { export const value = 1; export function read() { return value; } }",
    );
    var namespace_parser = Parser.init(allocator, &namespace_scanner);
    namespace_parser.configureFromExtension(".ts");
    _ = try namespace_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), namespace_parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(minify, &namespace_parser));

    var import_equals_scanner = try Scanner.init(
        allocator,
        "namespace Source { export let value = 40; } import Alias = Source; console.log(Alias.value + 2);",
    );
    var import_equals_parser = Parser.init(allocator, &import_equals_scanner);
    import_equals_parser.configureFromExtension(".ts");
    _ = try import_equals_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), import_equals_parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(minify, &import_equals_parser));

    var export_equals_scanner = try Scanner.init(allocator, "const value = 1; export = value;");
    var export_equals_parser = Parser.init(allocator, &export_equals_scanner);
    export_equals_parser.configureFromExtension(".ts");
    _ = try export_equals_parser.parse();
    try std.testing.expect(canMangleWithTransformSemantic(minify, &export_equals_parser));

    var namespace_export_scanner = try Scanner.init(allocator, "export as namespace TypeOnlyGlobal;");
    var namespace_export_parser = Parser.init(allocator, &namespace_export_scanner);
    namespace_export_parser.configureFromExtension(".ts");
    _ = try namespace_export_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), namespace_export_parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(minify, &namespace_export_parser));

    var enum_scanner = try Scanner.init(allocator, "enum Color { Red }");
    var enum_parser = Parser.init(allocator, &enum_scanner);
    enum_parser.configureFromExtension(".ts");
    _ = try enum_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), enum_parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(minify, &enum_parser));

    var decorator_scanner = try Scanner.init(allocator, "function dec(value: any) {} class Box { @dec method() {} }");
    var decorator_parser = Parser.init(allocator, &decorator_scanner);
    decorator_parser.configureFromExtension(".ts");
    _ = try decorator_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), decorator_parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(minify, &decorator_parser));
    try std.testing.expect(canMangleWithTransformSemantic(.{
        .minify_identifiers = true,
        .experimental_decorators = true,
    }, &decorator_parser));
    try std.testing.expect(canMangleWithTransformSemantic(.{
        .minify_identifiers = true,
        .experimental_decorators = true,
        .emit_decorator_metadata = true,
    }, &decorator_parser));

    var qualified_metadata_scanner = try Scanner.init(
        allocator,
        "namespace Types { export class Local {} } function decorate(value: Types.Local) {} " ++
            "class Box { @decorate method(value: Types.Local) {} }",
    );
    var qualified_metadata_parser = Parser.init(allocator, &qualified_metadata_scanner);
    qualified_metadata_parser.configureFromExtension(".ts");
    _ = try qualified_metadata_parser.parse();
    try std.testing.expect(canMangleWithTransformSemantic(.{
        .minify_identifiers = true,
        .experimental_decorators = true,
        .emit_decorator_metadata = true,
    }, &qualified_metadata_parser));

    var unsupported_qualified_metadata_scanner = try Scanner.init(
        allocator,
        "namespace Types { export class Local {} } function decorate(value: Types . Local) {} " ++
            "class Box { @decorate method(value: Types . Local) {} }",
    );
    var unsupported_qualified_metadata_parser = Parser.init(allocator, &unsupported_qualified_metadata_scanner);
    unsupported_qualified_metadata_parser.configureFromExtension(".ts");
    _ = try unsupported_qualified_metadata_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), unsupported_qualified_metadata_parser.errors.items.len);
    try std.testing.expect(!canMangleWithTransformSemantic(.{
        .minify_identifiers = true,
        .experimental_decorators = true,
        .emit_decorator_metadata = true,
    }, &unsupported_qualified_metadata_parser));

    var class_scanner = try Scanner.init(
        allocator,
        "class Base { constructor(public value: number) {} read(): number { return this.value; } } " ++
            "class Box extends Base { amount: number = 2; read(): number { return super.read() + this.amount; } }",
    );
    var class_parser = Parser.init(allocator, &class_scanner);
    class_parser.configureFromExtension(".ts");
    _ = try class_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), class_parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(minify, &class_parser));

    var static_block_scanner = try Scanner.init(
        allocator,
        "function run(value: number) { class Box { static { const local = 99; Box.result = local + value; } } return Box.result; }",
    );
    var static_block_parser = Parser.init(allocator, &static_block_scanner);
    static_block_parser.configureFromExtension(".ts");
    _ = try static_block_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), static_block_parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(minify, &static_block_parser));

    var private_class_scanner = try Scanner.init(
        allocator,
        "class Base { baseValue(): number { return 7; } } " ++
            "function make(value: number) { const args = value + 1; return class Generated extends Base { " ++
            "#state = args; static #count = 0; " ++
            "constructor(offset: number) { super(); this.#state += offset; Generated.#count++; } " ++
            "#read(delta: number): number { return this.#state + delta + super.baseValue(); } " ++
            "get value(): number { const args = 1000; return this.#read(2) + args; } " ++
            "evaluated(): number { return eval('args'); } " ++
            "hasState(target: object): boolean { return #state in target; } " ++
            "static count(): number { return Generated.#count; } " ++
            "static hasCount(target: object): boolean { return #count in target; } }; }",
    );
    var private_class_parser = Parser.init(allocator, &private_class_scanner);
    private_class_parser.configureFromExtension(".ts");
    _ = try private_class_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), private_class_parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(minify, &private_class_parser));

    var accessor_scanner = try Scanner.init(
        allocator,
        "function make(value: number) { const outer = value + 1; return class Generated { " ++
            "accessor value = outer; static accessor count = 0; " ++
            "constructor(delta: number) { this.value += delta; Generated.count++; } " ++
            "}; }",
    );
    var accessor_parser = Parser.init(allocator, &accessor_scanner);
    accessor_parser.configureFromExtension(".ts");
    _ = try accessor_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), accessor_parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(minify, &accessor_parser));
}

test "#4819 Flow Stage 3 decorators reuse the transform semantic graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "// @flow\nfunction dec(value, context) { return value; } " ++
        "@dec class Box { @dec read(input) { return input; } }";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    _ = try parser.parse();
    try std.testing.expect(parser.is_flow);
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(.{ .minify_identifiers = true }, &parser));
    try std.testing.expect(!canMangleWithTransformSemantic(.{
        .minify_identifiers = true,
        .experimental_decorators = true,
    }, &parser));
    try std.testing.expect(!canMangleWithTransformSemantic(.{
        .minify_identifiers = true,
        .emit_decorator_metadata = true,
    }, &parser));
}

test "#4819 native and downlevel using reuse the transform graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const minify: TranspileOptions = .{ .minify_identifiers = true };
    const ts_source = "function run(resource: any) { using local = resource; return local; } " ++
        "async function wait(resource: any) { await using local = resource; return local; }";

    var ts_scanner = try Scanner.init(allocator, ts_source);
    var ts_parser = Parser.init(allocator, &ts_scanner);
    ts_parser.configureFromExtension(".ts");
    _ = try ts_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), ts_parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(minify, &ts_parser));
    const downlevel: TranspileOptions = .{
        .minify_identifiers = true,
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    };
    try std.testing.expect(canMangleWithTransformSemantic(downlevel, &ts_parser));

    var flow_scanner = try Scanner.init(allocator, "// @flow\nfunction run(resource) { using local = resource; return local; }");
    var flow_parser = Parser.init(allocator, &flow_scanner);
    flow_parser.configureFromExtension(".js");
    _ = try flow_parser.parse();
    try std.testing.expect(flow_parser.is_flow);
    try std.testing.expectEqual(@as(usize, 0), flow_parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(minify, &flow_parser));
    try std.testing.expect(canMangleWithTransformSemantic(downlevel, &flow_parser));

    var js_scanner = try Scanner.init(allocator, "function run(resource) { using local = resource; return local; }");
    var js_parser = Parser.init(allocator, &js_scanner);
    js_parser.configureFromExtension(".js");
    _ = try js_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), js_parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(downlevel, &js_parser));

    var result = try transpile(allocator, "function run(resource: any) { using local = resource; return local; }", "input.ts", minify);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "using ") != null);

    var downlevel_result = try transpile(
        allocator,
        "async function wait(resource: any, _stack: any, _error: any, _hasError: any, _: any, __using: any, __callDispose: any) { " ++
            "using local = resource; await using asyncLocal = resource; return local + asyncLocal + _stack; }",
        "input.ts",
        downlevel,
    );
    defer downlevel_result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, downlevel_result.code, "__using") != null);
    try std.testing.expect(std.mem.indexOf(u8, downlevel_result.code, "__callDispose") != null);
    var output_scanner = try Scanner.init(allocator, downlevel_result.code);
    var output_parser = Parser.init(allocator, &output_scanner);
    output_parser.configureFromExtension(".mjs");
    _ = try output_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), output_parser.errors.items.len);
    for (output_parser.ast.nodes.items) |node| {
        if (node.tag == .variable_declaration) {
            try std.testing.expect(!output_parser.ast.variableDeclarationKind(node).isUsing());
        }
    }
    var output_analyzer = SemanticAnalyzer.init(allocator, &output_parser.ast);
    output_analyzer.is_module = true;
    try output_analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), output_analyzer.errors.items.len);
}

test "#4819 standalone mangling names namespace IIFE parameters from their SymbolIds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);

    // This drives `hot` to the `_N` Base54 slot. The namespace parameter starts
    // with a collision-free source spelling, then receives a distinct final
    // name from its own SymbolId so it cannot capture `hot`.
    for (0..1841) |i| {
        const declaration = try std.fmt.allocPrint(allocator, "const v{d} = {d}; void v{d};\n", .{ i, i, i });
        try source.appendSlice(allocator, declaration);
    }
    try source.appendSlice(
        allocator,
        "const hot = 42;\n" ++
            "namespace N { export function read() { return hot; } }\n" ++
            "if (N.read() !== 42) throw new Error('namespace capture');\n",
    );

    var result = try transpile(allocator, source.items, "input.ts", .{ .minify_identifiers = true });
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "((_N) =>") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "const _N = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "return _N;") != null);
}

test "#4819 TypeScript JSX lowering reuses the transform graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const automatic: TranspileOptions = .{ .minify_identifiers = true, .jsx_runtime = .automatic };
    const automatic_source = "const _jsx = 1, _jsxs = 2, _Fragment = 3; " ++
        "export function View() { return <><div value={_jsx} /><span>{_jsxs + _Fragment}</span></>; }";

    var automatic_scanner = try Scanner.init(allocator, automatic_source);
    var automatic_parser = Parser.init(allocator, &automatic_scanner);
    automatic_parser.configureFromExtension(".tsx");
    _ = try automatic_parser.parse();
    try std.testing.expect(automatic_parser.ast.has_jsx);
    try std.testing.expectEqual(@as(usize, 0), automatic_parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(automatic, &automatic_parser));

    var automatic_result = try transpile(allocator, automatic_source, "input.tsx", automatic);
    defer automatic_result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, automatic_result.code, "react/jsx-runtime") != null);
    var automatic_output_scanner = try Scanner.init(allocator, automatic_result.code);
    var automatic_output_parser = Parser.init(allocator, &automatic_output_scanner);
    automatic_output_parser.configureFromExtension(".mjs");
    _ = try automatic_output_parser.parse();
    var automatic_output_analyzer = SemanticAnalyzer.init(allocator, &automatic_output_parser.ast);
    automatic_output_analyzer.is_module = true;
    try automatic_output_analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), automatic_output_analyzer.errors.items.len);
    try std.testing.expectEqual(@as(usize, 0), automatic_output_analyzer.unresolved_references.count());

    const classic: TranspileOptions = .{
        .minify_identifiers = true,
        .jsx_runtime = .classic,
        .jsx_factory = "h",
        .jsx_fragment = "Frag",
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    };
    const classic_source = "const h = (type, props) => ({ type, props }), Frag = {}; " ++
        "export const View = () => <><div /></>;";
    var classic_scanner = try Scanner.init(allocator, classic_source);
    var classic_parser = Parser.init(allocator, &classic_scanner);
    classic_parser.configureFromExtension(".tsx");
    _ = try classic_parser.parse();
    try std.testing.expect(classic_parser.ast.has_jsx);
    try std.testing.expect(canMangleWithTransformSemantic(classic, &classic_parser));

    var classic_result = try transpile(allocator, classic_source, "input.tsx", classic);
    defer classic_result.deinit(allocator);
    var classic_output_scanner = try Scanner.init(allocator, classic_result.code);
    var classic_output_parser = Parser.init(allocator, &classic_output_scanner);
    classic_output_parser.configureFromExtension(".mjs");
    _ = try classic_output_parser.parse();
    var classic_output_analyzer = SemanticAnalyzer.init(allocator, &classic_output_parser.ast);
    classic_output_analyzer.is_module = true;
    try classic_output_analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), classic_output_analyzer.errors.items.len);
    try std.testing.expectEqual(@as(usize, 0), classic_output_analyzer.unresolved_references.count());
}

test "#4819 Flow match, enum, classes, private fields, and accessors reuse the transform graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const minify: TranspileOptions = .{ .minify_identifiers = true };

    var scanner = try Scanner.init(allocator, "// @flow\ntype Alias = number; const value: Alias = 1;");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    _ = try parser.parse();
    try std.testing.expect(parser.is_flow);
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(minify, &parser));

    const runtime_sources = [_]struct { source: []const u8, path: []const u8, tag: ast_mod.Node.Tag }{
        .{ .source = "// @flow\nenum Color { Red }", .path = ".js", .tag = .flow_enum_declaration },
        .{ .source = "// @flow\nfunction classify(value) { return match (value) { 1 => 'one', _ => 'other' }; }", .path = ".js", .tag = .flow_match_expression },
        .{ .source = "// @flow\ncomponent Card(ref?: mixed, ...props: { label?: string }) { return null; }", .path = ".js", .tag = .flow_component_wrapper },
        .{ .source = "// @flow\nclass Box { read(value: number): number { return value; } }", .path = ".js", .tag = .class_declaration },
        .{ .source = "// @flow\nclass Vault { #value: number = 0; read(value: number) { this.#value = value; return this.#value; } }", .path = ".js", .tag = .private_field_expression },
        .{ .source = "// @flow\nclass Counter { accessor value: number = 0; add(value: number) { this.value += value; return this.value; } }", .path = ".js", .tag = .accessor_property },
        .{ .source = "// @flow\nfunction dec(value, context) { return value; } @dec class Box { @dec read(input) { return input; } }", .path = ".js", .tag = .decorator },
    };
    for (runtime_sources) |item| {
        var runtime_scanner = try Scanner.init(allocator, item.source);
        var runtime_parser = Parser.init(allocator, &runtime_scanner);
        runtime_parser.configureFromExtension(item.path);
        _ = try runtime_parser.parse();
        try std.testing.expect(runtime_parser.is_flow);
        try std.testing.expectEqual(@as(usize, 0), runtime_parser.errors.items.len);
        var has_runtime_tag = false;
        for (runtime_parser.ast.nodes.items) |node| {
            if (node.tag == item.tag) has_runtime_tag = true;
        }
        try std.testing.expect(has_runtime_tag);
        try std.testing.expectEqual(
            item.tag == .flow_match_expression or
                item.tag == .flow_enum_declaration or
                item.tag == .flow_component_wrapper or
                item.tag == .class_declaration or
                item.tag == .private_field_expression or
                item.tag == .accessor_property or
                item.tag == .decorator,
            canMangleWithTransformSemantic(minify, &runtime_parser),
        );
    }

    var jsx_scanner = try Scanner.init(allocator, "// @flow\nconst view = <div />;");
    var jsx_parser = Parser.init(allocator, &jsx_scanner);
    jsx_parser.configureFromExtension(".jsx");
    _ = try jsx_parser.parse();
    try std.testing.expect(jsx_parser.is_flow);
    try std.testing.expect(jsx_parser.ast.has_jsx);
    try std.testing.expect(canMangleWithTransformSemantic(minify, &jsx_parser));

    var flow_component_jsx_scanner = try Scanner.init(allocator, "// @flow\ncomponent Card(ref?: mixed, ...props: { label?: string }) { return <div />; }");
    var flow_component_jsx_parser = Parser.init(allocator, &flow_component_jsx_scanner);
    flow_component_jsx_parser.configureFromExtension(".jsx");
    _ = try flow_component_jsx_parser.parse();
    try std.testing.expect(flow_component_jsx_parser.is_flow);
    try std.testing.expect(flow_component_jsx_parser.ast.has_jsx);
    try std.testing.expect(canMangleWithTransformSemantic(minify, &flow_component_jsx_parser));
}

test "#4819 Flow component and JSX lowering retain generated and source identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const options: TranspileOptions = .{ .flow = true, .minify_identifiers = true, .jsx_runtime = .automatic };
    const source = "// @flow\nimport React from 'react'; " ++
        "export component View(ref?: mixed, value: number, ...props: { label?: string }) { " ++
        "return <><div value={value + _jsx + _jsxs + _Fragment + View_withRef} />{props.label}</>; } " ++
        "const _jsx = 1, _jsxs = 2, _Fragment = 3, View_withRef = 4;";

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".jsx");
    _ = try parser.parse();
    try std.testing.expect(parser.is_flow);
    try std.testing.expect(parser.ast.has_jsx);
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(options, &parser));

    var result = try transpile(allocator, source, "input.jsx", options);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "React.forwardRef") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "react/jsx-runtime") != null);

    var output_scanner = try Scanner.init(allocator, result.code);
    var output_parser = Parser.init(allocator, &output_scanner);
    output_parser.configureFromExtension(".mjs");
    _ = try output_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), output_parser.errors.items.len);
    var output_analyzer = SemanticAnalyzer.init(allocator, &output_parser.ast);
    output_analyzer.is_module = true;
    try output_analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), output_analyzer.errors.items.len);
    try std.testing.expectEqual(@as(usize, 0), output_analyzer.unresolved_references.count());

    // The `forwardRef` argument must resolve to the generated helper function,
    // not to the colliding source binding `View_withRef`.
    var helper_symbol: ?u32 = null;
    var forward_ref_argument_symbol: ?u32 = null;
    for (output_parser.ast.nodes.items) |node| {
        if (node.tag == .function_declaration) {
            const name_raw = output_parser.ast.extra_data.items[node.data.extra + ast_mod.FunctionExtra.name];
            const name_index: usize = name_raw;
            if (name_index < output_analyzer.symbol_ids.items.len)
                helper_symbol = output_analyzer.symbol_ids.items[name_index];
        }
        if (node.tag != .call_expression) continue;
        const call_extra = node.data.extra;
        if (call_extra + 2 >= output_parser.ast.extra_data.items.len) continue;
        const callee: ast_mod.NodeIndex = @enumFromInt(output_parser.ast.extra_data.items[call_extra]);
        if (callee.isNone() or output_parser.ast.getNode(callee).tag != .static_member_expression) continue;
        const member_extra = output_parser.ast.getNode(callee).data.extra;
        if (member_extra + 1 >= output_parser.ast.extra_data.items.len) continue;
        const property: ast_mod.NodeIndex = @enumFromInt(output_parser.ast.extra_data.items[member_extra + 1]);
        if (property.isNone() or !std.mem.eql(u8, output_parser.ast.getText(output_parser.ast.getNode(property).span), "forwardRef")) continue;
        const args_start = output_parser.ast.extra_data.items[call_extra + 1];
        const args_len = output_parser.ast.extra_data.items[call_extra + 2];
        if (args_len != 1 or args_start >= output_parser.ast.extra_data.items.len) continue;
        const argument: ast_mod.NodeIndex = @enumFromInt(output_parser.ast.extra_data.items[args_start]);
        const argument_raw = @intFromEnum(argument);
        if (argument_raw < output_analyzer.symbol_ids.items.len)
            forward_ref_argument_symbol = output_analyzer.symbol_ids.items[argument_raw];
    }
    try std.testing.expect(helper_symbol != null);
    try std.testing.expect(forward_ref_argument_symbol != null);
    try std.testing.expectEqual(helper_symbol, forward_ref_argument_symbol);

    var source_collision_symbol: ?u32 = null;
    for (output_parser.ast.nodes.items) |node| {
        if (node.tag != .variable_declarator) continue;
        const extra = node.data.extra;
        if (extra + 2 >= output_parser.ast.extra_data.items.len) continue;
        const binding: ast_mod.NodeIndex = @enumFromInt(output_parser.ast.extra_data.items[extra]);
        const initializer: ast_mod.NodeIndex = @enumFromInt(output_parser.ast.extra_data.items[extra + 2]);
        if (binding.isNone() or initializer.isNone()) continue;
        const value = output_parser.ast.getNode(initializer);
        if (value.tag != .numeric_literal or !std.mem.eql(u8, output_parser.ast.getText(value.span), "4")) continue;
        const binding_raw = @intFromEnum(binding);
        if (binding_raw < output_analyzer.symbol_ids.items.len)
            source_collision_symbol = output_analyzer.symbol_ids.items[binding_raw];
    }
    try std.testing.expect(source_collision_symbol != null);
    try std.testing.expect(source_collision_symbol.? != helper_symbol.?);
    var source_collision_reads: usize = 0;
    for (output_parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .identifier_reference or raw >= output_analyzer.symbol_ids.items.len) continue;
        if (output_analyzer.symbol_ids.items[raw] == source_collision_symbol) source_collision_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), source_collision_reads);
}

test "#4819 Flow component and JSX lowering retain graph in classic runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const options: TranspileOptions = .{
        .flow = true,
        .minify_identifiers = true,
        .jsx_runtime = .classic,
    };
    const source = "// @flow\nimport React from 'react'; " ++
        "export component View(ref?: mixed, value: number, ...props: { label?: string }) { " ++
        "return <div>{value + View_withRef + (props.label ? 1 : 0)}</div>; } " ++
        "const View_withRef = 4;";

    var result = try transpile(allocator, source, "input.jsx", options);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "React.forwardRef") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "React.createElement") != null);

    var output_scanner = try Scanner.init(allocator, result.code);
    var output_parser = Parser.init(allocator, &output_scanner);
    output_parser.configureFromExtension(".mjs");
    _ = try output_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), output_parser.errors.items.len);
    var output_analyzer = SemanticAnalyzer.init(allocator, &output_parser.ast);
    output_analyzer.is_module = true;
    try output_analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), output_analyzer.errors.items.len);
    try std.testing.expectEqual(@as(usize, 0), output_analyzer.unresolved_references.count());
}

test "#4819 Flow JSX lowering reuses the transform graph without a component wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const options: TranspileOptions = .{ .flow = true, .minify_identifiers = true, .jsx_runtime = .automatic };
    const source = "// @flow\nconst _jsx = 1, _jsxs = 2, _Fragment = 3; " ++
        "export function View(props: { value: number }) { return <><div value={_jsx} /><span>{_jsxs + _Fragment + props.value}</span></>; }";

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".jsx");
    _ = try parser.parse();
    try std.testing.expect(parser.is_flow);
    try std.testing.expect(parser.ast.has_jsx);
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    try std.testing.expect(canMangleWithTransformSemantic(options, &parser));

    var result = try transpile(allocator, source, "input.jsx", options);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "react/jsx-runtime") != null);

    var output_scanner = try Scanner.init(allocator, result.code);
    var output_parser = Parser.init(allocator, &output_scanner);
    output_parser.configureFromExtension(".mjs");
    _ = try output_parser.parse();
    try std.testing.expectEqual(@as(usize, 0), output_parser.errors.items.len);
    var output_analyzer = SemanticAnalyzer.init(allocator, &output_parser.ast);
    output_analyzer.is_module = true;
    try output_analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), output_analyzer.errors.items.len);
    try std.testing.expectEqual(@as(usize, 0), output_analyzer.unresolved_references.count());
}

/// fast 와 full 양쪽 경로의 출력이 expected 와 일치하는지 검증. parity 만으로는
/// 둘이 *동일하게 잘못된* 출력을 내도 통과해버리므로, expected ground truth (Babel
/// preset-typescript 출력 기반) 도 함께 확정.
fn expectTranspileOutput(
    source: []const u8,
    expected: []const u8,
    file_path: []const u8,
    options: TranspileOptions,
) !void {
    var fast = try transpileWithCallbackInternal(
        std.testing.allocator,
        source,
        file_path,
        options,
        null,
        false,
    );
    defer fast.deinit(std.testing.allocator);

    var full = try transpileWithCallbackInternal(
        std.testing.allocator,
        source,
        file_path,
        options,
        null,
        true,
    );
    defer full.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(expected, fast.code);
    try std.testing.expectEqualStrings(expected, full.code);
}

fn expectFastFullParity(
    expected: SemanticRequirement,
    source: []const u8,
    file_path: []const u8,
    options: TranspileOptions,
) !void {
    const plan = try testTransformPlan(source, file_path, options);
    try std.testing.expectEqual(expected, plan.semantic);

    var fast = try transpileWithCallbackInternal(
        std.testing.allocator,
        source,
        file_path,
        options,
        null,
        false,
    );
    defer fast.deinit(std.testing.allocator);

    var full = try transpileWithCallbackInternal(
        std.testing.allocator,
        source,
        file_path,
        options,
        null,
        true,
    );
    defer full.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(full.code, fast.code);
    try std.testing.expectEqual(full.has_helpers, fast.has_helpers);
    try std.testing.expectEqual(@as(usize, 0), fast.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), full.diagnostics.len);
}

test "deep left-assoc binary chain does not overflow the stack (#4123)" {
    // `0 + 1 + 2 + … (N항)` 은 N-deep 좌편향 BinaryExpression 트리. 재귀 visitor
    // (semantic visitNode / transformer visitBinaryNode / codegen emitBinary)가 이 깊이에서
    // 스택 오버플로우했다(#4123, depth ~5000 에서 SIGSEGV). 좌 스파인 반복 평탄화 후 정상 처리.
    const n: usize = 20000; // pre-fix 크래시 임계(~4000-5000) 를 넉넉히 초과.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "const x = 0");
    var buf: [24]u8 = undefined;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        try src.appendSlice(std.testing.allocator, try std.fmt.bufPrint(&buf, " + {d}", .{i}));
    }
    try src.appendSlice(std.testing.allocator, ";\n");

    // full=true 로 semantic 경로(#3)까지 포함해 세 site 모두 거친다.
    var result = try transpileWithCallbackInternal(
        std.testing.allocator,
        src.items,
        "input.js",
        .{},
        null,
        true,
    );
    defer result.deinit(std.testing.allocator);

    // 크래시 없이 도달 + 진단 0 + 출력이 모든 `+`(N-1 개)를 보존(codegen 정확성).
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expectEqual(n - 1, std.mem.count(u8, result.code, "+"));
}

test "deep binary chain with minify does not overflow (#4123 flag-gated walkers)" {
    // `const x = a + a + … (N항)` (a=immutable const, x single-use) 를 minify_syntax 로 처리하면
    // single-use inline 판정이 `allInnerReferencesImmutable` 로 깊은 체인을 순회한다(주 커버 대상).
    // 재귀판이면 여기서 스택 오버플로우(#4123). 반복(walkPreorderIterative) 변환 후 정상.
    // (decrementRefs/containsDirectEval/hasTopLevelAwait 의 깊은-체인 비크래시는 CLI e2e 로 확인.)
    const n: usize = 20000;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "const a = 1;\nconst x = a");
    var i: usize = 1;
    while (i < n) : (i += 1) try src.appendSlice(std.testing.allocator, " + a");
    try src.appendSlice(std.testing.allocator, ";\nconsole.log(x);\n");

    var result = try transpileWithCallbackInternal(
        std.testing.allocator,
        src.items,
        "input.js",
        .{ .minify_syntax = true },
        null,
        true,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "deep chain under named-import binding-lite shadow scan does not overflow (#4123 PR-2c)" {
    // `.ts` + named import → fast-path 의 buildTransformPlan 이 hasUnsupportedNamedImportLocalBindingShadow
    // → scanForUnsupportedBindingLiteShadow ↔ scanChildrenForUnsupportedBindingLiteShadow 로 top-level
    // 식을 순회한다. 깊은 좌결합 체인(`a + a + …`)이 그 generic descent 를 N-deep **상호재귀**시켜
    // SIGSEGV 였다(#4123, named-import + 수만 항 실측). 반복 worklist 변환 후 정상 — shadow 없으니
    // plan 은 `.bindings` 로 해소돼야 한다(크래시 없이 도달했다는 증거). fast_path_disabled=false 로
    // 호출해야 이 스캔 경로를 탄다(true 면 buildTransformPlan 이 즉시 .full 반환하고 스캔 skip).
    const n: usize = 20000; // pre-fix 크래시 임계(수천 항)를 넉넉히 초과.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "import { Foo, Bar } from \"./m\";\nconst a = 1;\nconst r = a");
    var i: usize = 1;
    while (i < n) : (i += 1) try src.appendSlice(std.testing.allocator, " + a");
    try src.appendSlice(std.testing.allocator, ";\nFoo();\nBar(r);\n");

    const plan = try testTransformPlan(src.items, "input.ts", .{});
    try std.testing.expectEqual(SemanticRequirement.bindings, plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.named_import_binding_elision, plan.reason);
}

test "deep chain using named import does not overflow value-use marking (#4123 PR-2c)" {
    // semantic=.bindings 경로(named-import elision)는 markBindingLiteValueUses 로 import 사용처를
    // 마킹하며 식 전체를 순회한다(generic descent = 같은 value_context 로 자식 재귀). import 를 깊은
    // 좌결합 체인에서 쓰면 N-deep 재귀 → SIGSEGV 였다(#4123). switch 본체를 per-node 함수로 추출 후
    // generic 노드만 worklist 로 평탄화해 해소. fast_path_disabled=false 로 호출해 .bindings 실행
    // 경로(markBindingLiteValueUses)를 탄다. Foo 가 쓰이므로 import 는 보존(elision 안 됨).
    const n: usize = 20000;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "import { Foo } from \"./m\";\nexport const r = Foo");
    var i: usize = 1;
    while (i < n) : (i += 1) try src.appendSlice(std.testing.allocator, " + Foo");
    try src.appendSlice(std.testing.allocator, ";\n");

    var result = try transpileWithCallbackInternal(
        std.testing.allocator,
        src.items,
        "input.ts",
        .{},
        null,
        false, // fast-path enabled → .bindings 경로(markBindingLiteValueUses) 실행
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "Foo") != null);
}

test "TransformPlan: simple TypeScript strip skips semantic" {
    const plan = try testTransformPlan(
        "export const x: number = 1;\nexport function f(v: string): string { return v; }\ninterface Foo { x: number }\ntype Bar = string;\n",
        "input.ts",
        .{},
    );

    try std.testing.expectEqual(SemanticRequirement.none, plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.simple_ts_strip, plan.reason);
    try std.testing.expect(plan.strip_types_only);
}

test "TransformPlan: runtime-sensitive syntax keeps full semantic" {
    const cases = [_]struct {
        source: []const u8,
        reason: SemanticPlanReason,
    }{
        .{ .source = "enum Color { Red }\n", .reason = .ast_requires_runtime_transform },
        .{ .source = "namespace N { export const x = 1 }\n", .reason = .ast_requires_runtime_transform },
        .{ .source = "class C { #x = 1 }\n", .reason = .ast_requires_runtime_transform },
    };

    for (cases) |case| {
        const plan = try testTransformPlan(case.source, "input.ts", .{});
        try std.testing.expectEqual(SemanticRequirement.full, plan.semantic);
        try std.testing.expectEqual(case.reason, plan.reason);
    }
}

test "TransformPlan: Flow source is classified before generic non-TS source" {
    const flow_plan = try testTransformPlan("// @flow\nconst value: string = 'x';\n", "input.js", .{ .flow = true });
    try std.testing.expectEqual(SemanticRequirement.full, flow_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.flow_source, flow_plan.reason);

    const js_plan = try testTransformPlan("const value = 1;\n", "input.js", .{});
    try std.testing.expectEqual(SemanticRequirement.full, js_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.non_ts_source, js_plan.reason);
}

test "TransformPlan: named import TypeScript strip uses binding-lite semantic" {
    const plan = try testTransformPlan(
        "import { type A, B } from './bar';\nexport const x: A = B();\n",
        "input.ts",
        .{},
    );

    try std.testing.expectEqual(SemanticRequirement.bindings, plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.named_import_binding_elision, plan.reason);
    try std.testing.expect(plan.strip_types_only);
}

test "TransformPlan: scope-local named import shadows stay on binding-lite route" {
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
    }{
        .{
            .name = "block lexical shadow with outer value use",
            .source =
            \\import { Foo } from "./lib";
            \\{ const Foo = 1; Foo; }
            \\Foo();
            ,
        },
        .{
            .name = "catch binding shadow with try body value use",
            .source =
            \\import { Foo } from "./lib";
            \\try { Foo(); } catch (Foo) { Foo; }
            ,
        },
        .{
            .name = "nested block shadow with outer value use",
            .source =
            \\import { Foo } from "./lib";
            \\{
            \\  { const Foo = 1; Foo; }
            \\  Foo();
            \\}
            ,
        },
        .{
            .name = "block lexical shadow covers earlier references in the same block",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\{
            \\  Foo;
            \\  const Foo = Bar();
            \\}
            \\Foo();
            ,
        },
        .{
            .name = "function var shadow with outer value use",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\function f() { var Foo = Bar(); return Foo; }
            \\Foo();
            ,
        },
        .{
            .name = "function block var shadow stays function scoped",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\function f() {
            \\  if (ok) { var Foo = Bar(); }
            \\  return Foo;
            \\}
            \\Foo();
            ,
        },
        .{
            .name = "named function expression self-name shadows import locally",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\const fn = function Foo() { return Foo; };
            \\Foo();
            \\Bar();
            ,
        },
        .{
            .name = "named function expression self-name shadows parameter default",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\const fn = function Foo(value = Foo) { return value; };
            \\Bar();
            ,
        },
    };

    for (cases) |case| {
        const plan = try testTransformPlan(case.source, "input.ts", .{});
        std.testing.expectEqual(SemanticRequirement.bindings, plan.semantic) catch |err| {
            std.debug.print("scope-local route failed for case '{s}', reason={s}\n", .{ case.name, @tagName(plan.reason) });
            return err;
        };
    }
}

test "TransformPlan: ambiguous or overflowing named import shadows keep full semantic" {
    const top_level = try testTransformPlan(
        "import { Foo } from './x';\nconst Foo = 1;\nexport { Foo };\n",
        "input.ts",
        .{},
    );
    try std.testing.expectEqual(SemanticRequirement.full, top_level.semantic);
    try std.testing.expectEqual(SemanticPlanReason.binding_shadow_requires_full_semantic, top_level.reason);

    const top_level_block_var_shadow = try testTransformPlan(
        "import { Foo } from './x';\n{ var Foo = 1; }\nFoo();\n",
        "input.ts",
        .{},
    );
    try std.testing.expectEqual(SemanticRequirement.full, top_level_block_var_shadow.semantic);
    try std.testing.expectEqual(SemanticPlanReason.binding_shadow_requires_full_semantic, top_level_block_var_shadow.reason);

    const function_decl_shadow = try testTransformPlan(
        "import { Foo } from './x';\nfunction outer() { function Foo() {} return Foo; }\n",
        "input.ts",
        .{},
    );
    try std.testing.expectEqual(SemanticRequirement.full, function_decl_shadow.semantic);
    try std.testing.expectEqual(SemanticPlanReason.binding_shadow_requires_full_semantic, function_decl_shadow.reason);

    const function_var_shadow = try testTransformPlan(
        "import { Foo } from './x';\nfunction f() { var Foo = 1; return Foo; }\n",
        "input.ts",
        .{},
    );
    try std.testing.expectEqual(SemanticRequirement.bindings, function_var_shadow.semantic);
    try std.testing.expectEqual(SemanticPlanReason.named_import_binding_elision, function_var_shadow.reason);

    var function_expression_overflow_source: std.ArrayList(u8) = .empty;
    defer function_expression_overflow_source.deinit(std.testing.allocator);
    try function_expression_overflow_source.appendSlice(std.testing.allocator, "import { Foo");
    var j: usize = 0;
    while (j < 64) : (j += 1) {
        try function_expression_overflow_source.print(std.testing.allocator, ", I{d}", .{j});
    }
    try function_expression_overflow_source.appendSlice(std.testing.allocator, " } from './x';\nconst fn = function Foo(");
    j = 0;
    while (j < 64) : (j += 1) {
        try function_expression_overflow_source.print(std.testing.allocator, "I{d},", .{j});
    }
    try function_expression_overflow_source.appendSlice(std.testing.allocator, ") { return Foo; };\n");
    const function_expression_overflow_plan = try testTransformPlan(function_expression_overflow_source.items, "input.ts", .{});
    try std.testing.expectEqual(SemanticRequirement.full, function_expression_overflow_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.binding_shadow_requires_full_semantic, function_expression_overflow_plan.reason);

    var overflow_source: std.ArrayList(u8) = .empty;
    defer overflow_source.deinit(std.testing.allocator);
    try overflow_source.appendSlice(std.testing.allocator, "import {");
    var i: usize = 0;
    while (i < 65) : (i += 1) {
        try overflow_source.print(std.testing.allocator, " I{d},", .{i});
    }
    try overflow_source.appendSlice(std.testing.allocator, " } from './x';\nfunction f(");
    i = 0;
    while (i < 65) : (i += 1) {
        try overflow_source.print(std.testing.allocator, "I{d},", .{i});
    }
    try overflow_source.appendSlice(std.testing.allocator, ") {}\n");
    const overflow_plan = try testTransformPlan(overflow_source.items, "input.ts", .{});
    try std.testing.expectEqual(SemanticRequirement.full, overflow_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.binding_shadow_requires_full_semantic, overflow_plan.reason);
}

test "TransformPlan: default and namespace imports keep full semantic" {
    const default_plan = try testTransformPlan("import Foo from './bar';\nexport const x = 1;\n", "input.ts", .{});
    try std.testing.expectEqual(SemanticRequirement.full, default_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.import_shape_requires_full_semantic, default_plan.reason);

    const namespace_plan = try testTransformPlan("import * as Foo from './bar';\nexport const x = 1;\n", "input.ts", .{});
    try std.testing.expectEqual(SemanticRequirement.full, namespace_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.import_shape_requires_full_semantic, namespace_plan.reason);
}

test "TransformPlan: semantic-sensitive options keep full semantic" {
    const compat = @import("transformer/compat.zig");

    const minify_plan = try testTransformPlan("export const x: number = 1;\n", "input.ts", .{
        .minify_identifiers = true,
    });
    try std.testing.expectEqual(SemanticRequirement.full, minify_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.option_requires_transform_semantic, minify_plan.reason);

    const cjs_plan = try testTransformPlan("export const x: number = 1;\n", "input.ts", .{
        .module_format = .cjs,
    });
    try std.testing.expectEqual(SemanticRequirement.full, cjs_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.module_format_requires_semantic, cjs_plan.reason);

    const downlevel_plan = try testTransformPlan("export const x: number = 1;\n", "input.ts", .{
        .unsupported = compat.fromESTarget(.es5),
        .es_target = .es5,
    });
    try std.testing.expectEqual(SemanticRequirement.full, downlevel_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.target_requires_downlevel, downlevel_plan.reason);
}

test "ES2019 optional catch binding: synthesized name avoids outer variable shadow (#4415)" {
    // target < es2019 의 빈 catch{} lowering 이 합성하는 binding 이름이 catch body 가
    // 참조하는 외부 변수(_a)를 섀도잉하면, body 가 잡힌 에러 객체를 읽는 silent
    // miscompile 이 된다. full semantic 경로에서 충돌 회피가 동작하는지 검증.
    const compat = @import("transformer/compat.zig");
    var result = try transpileWithCallbackInternal(
        std.testing.allocator,
        "let _a = 5;\ntry { x(); } catch { _a; }\n",
        "input.ts",
        .{ .unsupported = compat.fromESTarget(.es2018), .es_target = .es2018 },
        null,
        true,
    );
    defer result.deinit(std.testing.allocator);

    // 외부 _a 를 피해 다른 이름을 써야 한다.
    try std.testing.expect(std.mem.indexOf(u8, result.code, "catch (_b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "catch (_a)") == null);
    // catch 파라미터는 그 자체로 선언이므로 hoist 된 `var _` 누수가 없어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, result.code, "var _") == null);
}

test "TransformPlan parity: fast TS strip matches full semantic output" {
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
    }{
        .{
            .name = "exported const with primitive annotation",
            .source =
            \\export const value: number = 1;
            ,
        },
        .{
            .name = "function params and return annotations",
            .source =
            \\export function add(a: number, b: number): number {
            \\  return a + b;
            \\}
            ,
        },
        .{
            .name = "interface and type-only declarations",
            .source =
            \\interface User { id: string; age?: number }
            \\type Maybe<T> = T | null;
            \\export const id: Maybe<string> = "a";
            ,
        },
        .{
            .name = "generic function and type parameters",
            .source =
            \\export function first<T extends { id: string }>(items: T[]): T | undefined {
            \\  return items[0];
            \\}
            ,
        },
        .{
            .name = "TS expression wrappers",
            .source =
            \\const raw: unknown = "value";
            \\export const a = raw as string;
            \\export const b = raw satisfies unknown;
            \\export const c = (raw as string)!;
            ,
        },
        .{
            .name = "default function declaration",
            .source =
            \\export default function main(input: string): string {
            \\  return input;
            \\}
            ,
        },
        .{
            .name = "directives and comments",
            .source =
            \\"use client";
            \\// keep the directive at the top
            \\export const action: () => void = () => {};
            ,
        },
        // D10 (ajv jtd.ts): `type X = ...; export { X };` — Babel preset-typescript 의
        // 자동 type-only export elision. full semantic 은 SPEC_FLAG_TYPE_ONLY 마킹으로
        // specifier 를 제거하므로 fast path 도 동일 출력이어야 한다.
        .{
            .name = "auto type-only export elision (type alias)",
            .source =
            \\type JTDOptions = { a: number };
            \\export { JTDOptions };
            ,
        },
        .{
            .name = "auto type-only export elision (interface)",
            .source =
            \\interface IFoo { a: number }
            \\export { IFoo };
            ,
        },
        .{
            .name = "auto type-only export elision (mixed type + value)",
            .source =
            \\type Bar = number;
            \\const baz = 1;
            \\export { Bar, baz };
            ,
        },
    };

    for (cases) |case| {
        expectFastFullParity(.none, case.source, "input.ts", .{}) catch |err| {
            std.debug.print("fast/full parity failed for case '{s}'\n", .{case.name});
            return err;
        };
    }
}

// D10 declaration merging — type alias 와 동명 value (const / class / function 등) 가
// 공존하면 value 우선이어야 한다 (Babel preset-typescript 동작). 이전 회귀: 모든
// 경로에서 export 가 잘못 drop 되어 runtime ReferenceError 가 발생했다. parity 테스트는
// "fast/full 둘 다 똑같이 잘못된" 케이스도 통과시키므로 expected output 으로 ground
// truth 확정.
test "TS auto type-only export: declaration merging preserves value binding" {
    try expectTranspileOutput(
        \\const X = 1;
        \\type X = number;
        \\export { X };
        \\
    ,
        \\const X = 1;
        \\export { X };
        \\
    ,
        "input.ts",
        .{},
    );

    try expectTranspileOutput(
        \\class C {}
        \\type C = string;
        \\export { C };
        \\
    ,
        \\class C {
        \\}
        \\export { C };
        \\
    ,
        "input.ts",
        .{},
    );

    try expectTranspileOutput(
        \\function f() {}
        \\type f = number;
        \\export { f };
        \\
    ,
        \\function f() {
        \\}
        \\export { f };
        \\
    ,
        "input.ts",
        .{},
    );

    // enum 은 value (IIFE 형태로 전개되어도 export 가 유지되어야 함)
    try expectTranspileOutput(
        \\enum E { A }
        \\export { E };
        \\
    ,
        \\var E = /* @__PURE__ */ ((E) => {E[E["A"]=0]="A";return E;})(E || {});
        \\export { E };
        \\
    ,
        "input.ts",
        .{},
    );
}

test "TS auto type-only export: named alias of default interface is elided" {
    try expectTranspileOutput(
        \\export default interface _Shape { value: number }
        \\export { _Shape as PublicShape };
        \\console.log("DEFAULT_INTERFACE_OK");
        \\
    ,
        \\console.log("DEFAULT_INTERFACE_OK");
        \\
    ,
        "input.ts",
        .{},
    );
}

// D13: top-level `declare class/function/var` 의 name 은 type-only binding.
// `export { X as Y };` 가 declare 만 reference 하면 specifier 가 자동 elide (Babel
// preset-typescript 동작). parser 가 top-level declare 를 strip 해 AST 에 사라지므로
// markAutoTypeOnlyExportSpecifiers 가 별도 sideband (`ast.type_only_binding_names`) 에서
// name 을 조회해야 한다.
test "Transpile: .d.ts declaration file emits empty output (D12.5)" {
    // tsc/Babel: `.d.ts` 는 declaration-only 파일이라 transpile 결과가 빈 출력.
    // 이전 ZNTC 는 ambient const initializer 면제만 처리하고 codegen 단계에서
    // 그대로 emit 해 `export const x;` 같은 invalid JS 가 나옴.
    try expectTranspileOutput(
        \\export const urlAlphabet: string;
        \\export const nanoid: () => string;
        \\
    ,
        "",
        "index.d.ts",
        .{},
    );

    // `.d.mts` / `.d.cts` 동일 처리
    try expectTranspileOutput(
        \\export const x: number;
    ,
        "",
        "lib.d.mts",
        .{},
    );

    try expectTranspileOutput(
        \\export const x: number;
    ,
        "",
        "lib.d.cts",
        .{},
    );

    // 일반 `.ts` 는 영향 없음 (regression guard)
    try expectTranspileOutput(
        \\export const x = 1;
        \\
    ,
        "export const x = 1;\n",
        "input.ts",
        .{},
    );
}

test "TS auto type-only export: default/namespace import + type alias mixed export (D13 layout)" {
    // collectAutoTypeOnlyDeclNames 가 default/namespace import specifier 의 local
    // 이름을 `extra_data[spec.data.extra]` 로 잘못 읽던 layout 버그 (D13 회귀).
    // 실제 layout 은 spec_node.span (string_ref) — 파서가 별도 name 노드 없이
    // 직접 저장 (codegen/analyzer 와 동일). 오독 시 default/namespace import 가
    // value_names 에 미등록 → markAutoTypeOnlyExportSpecifiers 가 같은 export
    // 블록의 type alias 와 함께 잘못 처리 → `Export 'T' is not defined` (ZNTC1201).
    //
    // 주의: D20 (forward `export {}; import default/namespace`) 은 별개 — analyzer
    // 의 import predeclare 가 필요해 bundler runtime-helper scope 모델 재설계 RFC.
    // 이 fix 는 layout 오독만 해결 (import 가 export 보다 *뒤* 인 forward 케이스는
    // 여전히 ZNTC1201 — RFC 범위).
    try expectTranspileOutput(
        \\import Foo from './foo';
        \\type T = number;
        \\export { Foo, T };
        \\
    ,
        \\import Foo from "./foo";
        \\export { Foo };
        \\
    ,
        "input.ts",
        .{},
    );

    // namespace import + type alias mixed
    try expectTranspileOutput(
        \\import * as ns from './mod';
        \\type T = number;
        \\export { ns, T };
        \\
    ,
        \\import * as ns from "./mod";
        \\export { ns };
        \\
    ,
        "input.ts",
        .{},
    );

    // default import alone, exported — value 보존 (회귀 가드)
    try expectTranspileOutput(
        \\import Foo from './foo';
        \\export { Foo };
        \\
    ,
        \\import Foo from "./foo";
        \\export { Foo };
        \\
    ,
        "input.ts",
        .{},
    );
}

test "TS auto type-only export: top-level declare bindings elide rename specifier (D13)" {
    // export declare class — Babel: `export {};` (ZNTC codegen 은 빈 export 통째 drop)
    try expectTranspileOutput(
        \\export declare class Foo {}
        \\export { Foo as Bar };
        \\
    ,
        \\
    ,
        "input.ts",
        .{},
    );

    // export declare function (단독 통과는 simple_ts_strip 인데, 다른 케이스도 동등)
    try expectTranspileOutput(
        \\export declare function _lte(): number;
        \\export { _lte as _max };
        \\
    ,
        \\
    ,
        "input.ts",
        .{},
    );

    // namespace import 가 선행하면 binding-lite path — 동일 결과
    try expectTranspileOutput(
        \\import * as foo from "./foo";
        \\export declare function _lte(): number;
        \\export { _lte as _max };
        \\
    ,
        \\import * as foo from "./foo";
        \\
    ,
        "input.ts",
        .{},
    );

    // non-export declare 도 동일
    try expectTranspileOutput(
        \\declare class Foo {}
        \\export { Foo };
        \\
    ,
        \\
    ,
        "input.ts",
        .{},
    );

    // declaration merging: value class 와 declare class 가 공존하면 value 우선
    try expectTranspileOutput(
        \\class A {}
        \\declare class B {}
        \\export { A, B };
        \\
    ,
        \\class A {
        \\}
        \\export { A };
        \\
    ,
        "input.ts",
        .{},
    );

    // declare namespace — ts_module_declaration 은 binary layout. extras[0] 으로 잘못
    // 읽으면 OOB panic. binary.left = name idx 가 정답.
    try expectTranspileOutput(
        \\declare namespace Foo {}
        \\export { Foo as Bar };
        \\
    ,
        \\
    ,
        "input.ts",
        .{},
    );

    // declare module "..." — binary.left 가 string_literal 이라 name 등록 skip.
    // 자체로 strip, 빈 export 도 strip.
    try expectTranspileOutput(
        \\declare module "*.svg" { const src: string; export default src; }
        \\export const value = 1;
        \\
    ,
        \\export const value = 1;
        \\
    ,
        "input.ts",
        .{},
    );
}

test "TransformPlan parity: binding-lite named import elision matches full semantic output" {
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        options: TranspileOptions = .{},
    }{
        .{
            .name = "inline type specifier removed and value specifier kept",
            .source =
            \\import { type A, B } from "./lib";
            \\export const value: A = B();
            ,
        },
        .{
            .name = "named import used only in type annotation is removed",
            .source =
            \\import { A } from "./lib";
            \\export function f(value: A): void {}
            ,
        },
        .{
            .name = "named import used in value expression is kept",
            .source =
            \\import { B } from "./lib";
            \\export const value = B();
            ,
        },
        .{
            .name = "aliased named import follows local binding",
            .source =
            \\import { Foo as Bar, Used } from "./lib";
            \\export type T = Bar;
            \\export const value = Used();
            ,
        },
        .{
            .name = "string named import follows alias binding",
            .source =
            \\import { "x" as x, y } from "./lib";
            \\export type T = typeof y;
            \\export const value = x();
            ,
        },
        .{
            .name = "multiple declarations and side effect import",
            .source =
            \\import "./setup";
            \\import { A, B } from "./a";
            \\import { C as D } from "./b";
            \\export type T = A | D;
            \\export const value = B();
            ,
        },
        .{
            .name = "export specifier is value use",
            .source =
            \\import { A } from "./lib";
            \\export { A };
            ,
        },
        .{
            .name = "computed property key is value use",
            .source =
            \\import { A } from "./lib";
            \\export const value = { [A]: 1 };
            ,
        },
        .{
            .name = "shorthand property is value use",
            .source =
            \\import { A } from "./lib";
            \\export const value = { A };
            ,
        },
        .{
            .name = "default parameter initializer is value use",
            .source =
            \\import { A } from "./lib";
            \\export function f(value = A()) {
            \\  return value;
            \\}
            ,
        },
        .{
            .name = "nested function body reference is value use",
            .source =
            \\import { A } from "./lib";
            \\export function outer() {
            \\  return function inner() {
            \\    return A();
            \\  };
            \\}
            ,
        },
        .{
            .name = "function parameter shadow does not keep import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function f(Foo = Foo) {
            \\  return Foo;
            \\}
            \\export const value = Bar();
            ,
        },
        .{
            .name = "arrow parameter shadow does not hide outer value use",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export const before = Foo();
            \\export const fn = (Foo) => Foo;
            \\export const after = Bar();
            ,
        },
        .{
            .name = "parameter shadow default can still use another import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function f(Foo = Bar()) {
            \\  return Foo;
            \\}
            ,
        },
        .{
            .name = "object destructuring parameter shadows import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function f({ Foo }) {
            \\  return Foo;
            \\}
            \\export const value = Bar();
            ,
        },
        .{
            .name = "object destructuring parameter default uses another import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function f({ x: Foo = Bar() }) {
            \\  return Foo;
            \\}
            ,
        },
        .{
            .name = "array destructuring parameter default uses another import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function f([Foo = Bar()]) {
            \\  return Foo;
            \\}
            ,
        },
        .{
            .name = "rest parameter shadows import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function f(...Foo) {
            \\  return Foo.length;
            \\}
            \\export const value = Bar();
            ,
        },
        .{
            .name = "nested function parameter shadow does not hide outer value use",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function outer() {
            \\  const first = Foo();
            \\  function inner(Foo = Bar()) {
            \\    return Foo;
            \\  }
            \\  return first + inner();
            \\}
            ,
        },
        .{
            .name = "nested arrow parameter shadow does not hide outer value use",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export const outer = () => {
            \\  const inner = (Foo = Bar()) => Foo;
            \\  return Foo() + inner();
            \\};
            ,
        },
        .{
            .name = "catch binding shadow does not hide try body import use",
            .source =
            \\import { Foo } from "./lib";
            \\try { Foo(); } catch (Foo) { Foo; }
            ,
        },
        .{
            .name = "block lexical shadow does not hide outer import use",
            .source =
            \\import { Foo } from "./lib";
            \\{ const Foo = 1; Foo; }
            \\Foo();
            ,
        },
        .{
            .name = "nested block lexical shadow does not hide outer import use",
            .source =
            \\import { Foo } from "./lib";
            \\{
            \\  { const Foo = 1; Foo; }
            \\  Foo();
            \\}
            ,
        },
        .{
            .name = "nested function catch and block shadows stay scoped",
            .source =
            \\import { Foo, Bar, Baz } from "./lib";
            \\export function outer(Foo = Bar()) {
            \\  try {
            \\    Baz();
            \\  } catch (Bar) {
            \\    { const Baz = Bar; Baz; }
            \\  }
            \\  return Foo;
            \\}
            \\export const value = Bar();
            ,
        },
        .{
            .name = "function var shadow does not keep import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function f() {
            \\  var Foo = Bar();
            \\  return Foo;
            \\}
            ,
        },
        .{
            .name = "nested function var shadow does not hide outer value use",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export const before = Foo();
            \\export function outer() {
            \\  if (ok) { var Foo = Bar(); }
            \\  return Foo;
            \\}
            ,
        },
        .{
            .name = "named function expression self-name does not keep import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export const fn = function Foo() {
            \\  return Foo;
            \\};
            \\export const value = Bar();
            ,
        },
        .{
            .name = "named function expression self-name does not hide outer value use",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export const fn = function Foo(value = Foo) {
            \\  return value;
            \\};
            \\export const value = Foo() + Bar();
            ,
        },
        .{
            .name = "local declaration initializer can use another import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\{
            \\  const Foo = Bar();
            \\  Foo;
            \\}
            ,
        },
        .{
            .name = "type-only import use mixed with value import use",
            .source =
            \\import { Foo, Bar, type Baz } from "./lib";
            \\type T = Foo | Baz;
            \\{ const Foo = 1; Foo; }
            \\export const value: T = Bar();
            ,
        },
        .{
            .name = "block lexical shadow covers declaration initializer order",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\{
            \\  Foo;
            \\  const Foo = Bar();
            \\}
            \\Foo();
            ,
        },
        .{
            .name = "destructuring local shadow initializer can use another import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\{
            \\  const { value: Foo = Bar() } = source;
            \\  Foo;
            \\}
            ,
        },
        .{
            // assignment_expression LHS (`Foo = expr`) 가 expression context 에서 walker arm
            // 에 잡혀 value_context=false 로 강제되면 import 가 잘못 elide 된다 — regression guard.
            .name = "assignment to imported name in expression keeps import",
            .source =
            \\import { Foo } from "./lib";
            \\Foo = something();
            ,
        },
        .{
            .name = "verbatim keeps value import but removes inline type specifier",
            .source =
            \\import { type A, B } from "./lib";
            \\export function f(value: A): void {}
            ,
            .options = .{ .verbatim_module_syntax = true },
        },
    };

    for (cases) |case| {
        expectFastFullParity(.bindings, case.source, "input.ts", case.options) catch |err| {
            std.debug.print("binding-lite parity failed for case '{s}'\n", .{case.name});
            return err;
        };
    }
}

test "TransformPlan: full-route guards for binding-lite follow-up" {
    const compat = @import("transformer/compat.zig");
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        path: []const u8 = "input.ts",
        options: TranspileOptions = .{},
    }{
        .{ .name = "default import", .source = "import Foo from './x';\nexport const x = 1;\n" },
        .{ .name = "namespace import", .source = "import * as Foo from './x';\nexport const x = 1;\n" },
        .{ .name = "jsx", .source = "import { Foo } from './x';\nexport const x = <Foo />;\n", .path = "input.tsx" },
        .{ .name = "enum", .source = "import { Foo } from './x';\nenum E { A }\n" },
        .{ .name = "namespace", .source = "import { Foo } from './x';\nnamespace N { export const x = 1 }\n" },
        .{ .name = "import equals", .source = "import { Foo } from './x';\nimport Bar = require('bar');\n" },
        .{ .name = "export assignment", .source = "import { Foo } from './x';\nexport = Foo;\n" },
        .{ .name = "class", .source = "import { Foo } from './x';\nclass C {}\n" },
        .{ .name = "private", .source = "import { Foo } from './x';\nconst obj = Foo.#x;\n" },
        .{ .name = "decorator", .source = "import { Foo } from './x';\n@dec class C {}\n" },
        .{ .name = "using", .source = "import { Foo } from './x';\nusing resource = Foo();\n" },
        .{ .name = "minify", .source = "import { Foo } from './x';\nFoo();\n", .options = .{ .minify_syntax = true } },
        .{ .name = "define", .source = "import { Foo } from './x';\nFoo();\n", .options = .{ .define = &.{.{ .key = "DEBUG", .value = "false" }} } },
        .{ .name = "drop", .source = "import { Foo } from './x';\nconsole.log(Foo);\n", .options = .{ .drop_console = true } },
        .{ .name = "cjs", .source = "import { Foo } from './x';\nFoo();\n", .options = .{ .module_format = .cjs } },
        .{ .name = "downlevel", .source = "import { Foo } from './x';\nFoo();\n", .options = .{ .unsupported = compat.fromESTarget(.es5), .es_target = .es5 } },
        .{ .name = "flow", .source = "import { Foo } from './x';\nexport const x: Foo = 1;\n", .path = "input.js", .options = .{ .flow = true } },
    };

    for (cases) |case| {
        const plan = testTransformPlan(case.source, case.path, case.options) catch |err| {
            std.debug.print("full-route guard parse failed for case '{s}'\n", .{case.name});
            return err;
        };
        std.testing.expectEqual(SemanticRequirement.full, plan.semantic) catch |err| {
            std.debug.print("full-route guard failed for case '{s}', reason={s}\n", .{ case.name, @tagName(plan.reason) });
            return err;
        };
    }
}

test "#4390 refresh hook-sig: _s component ref follows mangler rename" {
    // 컴포넌트 App 이 minify_identifiers 로 rename 되면 _s(Component, "sig") 의
    // Component 참조도 같은 이름을 따라야 한다. symbol_id 미전파 시 _s(App, ...) 로
    // 남아 dangling reference (App 는 rename 되어 더 이상 존재하지 않음).
    const src =
        \\function App() {
        \\  const x = useState(0);
        \\  useEffect(() => {}, []);
        \\  return null;
        \\}
    ;
    var r = try transpile(std.testing.allocator, src, "/src/App.tsx", .{
        .react_refresh = true,
        .react_refresh_hook_signatures = true,
        .minify_identifiers = true,
    });
    defer r.deinit(std.testing.allocator);
    // 컴포넌트가 rename 됐고, 등록 대입(`_c = <이름>`)과 서명 호출(`_s(<이름>, …)`)의 인자도
    // 같은 이름을 가리켜야 한다. `_c`·`_s` 자신도 합성 바인딩이라 짧은 이름으로 바뀔 수 있다.
    const fn_start = (std.mem.indexOf(u8, r.code, "function ") orelse return error.TestUnexpectedResult) + "function ".len;
    const fn_end = std.mem.indexOfScalarPos(u8, r.code, fn_start, '(') orelse return error.TestUnexpectedResult;
    const comp = r.code[fn_start..fn_end];
    try std.testing.expect(!std.mem.eql(u8, comp, "App"));
    const assign = try std.fmt.allocPrint(std.testing.allocator, " = {s};", .{comp});
    defer std.testing.allocator.free(assign);
    const sig_call = try std.fmt.allocPrint(std.testing.allocator, "({s}, \"useState", .{comp});
    defer std.testing.allocator.free(sig_call);
    try std.testing.expect(std.mem.indexOf(u8, r.code, assign) != null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, sig_call) != null);
    // dangling 원본 이름 참조가 남으면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, r.code, "(App,") == null);
}

test "#4493 구조분해 할당의 shorthand+기본값 프로퍼티도 rename 을 따라간다" {
    // `({stackWeight = 1} = o)` 는 cover grammar 로
    // assignment_target_property_identifier(left=바인딩, right=기본값, flags=shorthand_with_default)
    // 가 된다. codegen 이 이걸 longhand `key:value=default` 로 펼칠 때 value 위치를
    // 원본 span 으로 복사하면 mangler rename 을 건너뛴다 → 미선언 전역에 대입되고
    // (strict ESM 에선 ReferenceError) 진짜 지역 변수는 영영 대입되지 않는다.
    const src =
        \\export function buildStacks(boxes) {
        \\  let pos, stack, stackWeight;
        \\  ({ position: pos, options: { stack, stackWeight = 1 } } = boxes);
        \\  return pos + stack + stackWeight;
        \\}
    ;
    var r = try transpile(std.testing.allocator, src, "/src/a.js", .{
        .minify_identifiers = true,
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer r.deinit(std.testing.allocator);
    // key(프로퍼티 이름) 는 보존되고 value(바인딩) 는 rename 되어야 한다.
    // 버그 시: `stackWeight:stackWeight=1` (value 가 원본 이름 그대로).
    try std.testing.expect(std.mem.indexOf(u8, r.code, "stackWeight:stackWeight=") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "stackWeight:") != null);
    // 기본값 없는 shorthand(`stack`) 도 같은 규칙 — 이미 정상이던 대조군.
    try std.testing.expect(std.mem.indexOf(u8, r.code, "stack:stack") == null);
}

test "#4493 최상위(비중첩) 구조분해 할당의 shorthand+기본값도 동일" {
    // 중첩은 트리거 조건이 아니다 — 선언(`let {x = 1} = o`)이 아니라 **할당**
    // (`({x = 1} = o)`) 형태이기만 하면 최상위에서도 샌다.
    const src =
        \\export function f(o) {
        \\  let stackWeight;
        \\  ({ stackWeight = 1 } = o);
        \\  return stackWeight;
        \\}
    ;
    var r = try transpile(std.testing.allocator, src, "/src/a.js", .{
        .minify_identifiers = true,
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "stackWeight:stackWeight=") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "stackWeight:") != null);
}

test "#4493 TS namespace export 도 shorthand+기본값에서 ns 치환을 따라간다" {
    // 같은 raw-span 복사가 mangler rename 뿐 아니라 **ns_prefix 치환**(`x` → `N.x`) 도
    // 건너뛰었다. minify 와 무관하게 터지는 표면 — 수정 전에는 `({x:x=1}=o)` 로 방출돼
    // 자유변수(전역) 에 대입되고 `N.x` 는 초기값 그대로 남았다 (무성 오염).
    const src =
        \\namespace N {
        \\  export let x = 0;
        \\  export function f(o: any) { ({ x = 1 } = o); return x; }
        \\}
    ;
    var r = try transpile(std.testing.allocator, src, "/src/a.ts", .{});
    defer r.deinit(std.testing.allocator);
    // 대입 대상이 ns 멤버여야 한다. `x:x=1` 이면 전역에 대입 → N.x 는 영영 안 바뀐다.
    try std.testing.expect(std.mem.indexOf(u8, r.code, "N.x=1") != null or
        std.mem.indexOf(u8, r.code, "N.x = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "x:x=1") == null);
}

test "#4493 es5 다운레벨의 중첩 구조분해 대입 타겟도 rename 을 따라간다" {
    // es5 에서는 codegen 이 아니라 transformer 가 구조분해를 풀어낸다
    // (`{s, w = 1}` → `s = _ref.s, w = _ref.w === void 0 ? 1 : _ref.w`).
    // 이때 합성한 대입 타겟 노드에 symbol_id 를 물려주지 않으면 mangler rename 이
    // 스킵돼 원본 이름으로 대입된다 — 같은 #4493 이 다른 emit 경로로 재현된다.
    const src =
        \\export function buildStacks(box) {
        \\  var pos, stack, stackWeight;
        \\  ({ position: pos, options: { stack, stackWeight = 1 } } = box);
        \\  return pos + stack + stackWeight;
        \\}
    ;
    var r = try transpile(std.testing.allocator, src, "/src/a.js", .{
        .minify_identifiers = true,
        .minify_whitespace = true,
        .minify_syntax = true,
        .es_target = .es5,
        .unsupported = @import("transformer/compat.zig").fromESTarget(.es5),
    });
    defer r.deinit(std.testing.allocator);
    // 원본 이름으로의 **대입**이 남으면 미선언 전역 대입이다. `,` 앞을 붙여 대입 타겟만
    // 본다 — `_b.stackWeight===void 0` 같은 프로퍼티 읽기와 헷갈리지 않게.
    try std.testing.expect(std.mem.indexOf(u8, r.code, ",stack=") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, ",stackWeight=") == null);
    // 프로퍼티 읽기(`.stack` / `.stackWeight`)는 그대로 남아야 한다.
    try std.testing.expect(std.mem.indexOf(u8, r.code, ".stack") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, ".stackWeight") != null);
}

test "#4762 es5 기본값 매개변수의 기본값 검사도 매개변수 rename 을 따라간다" {
    // es5 는 `opts = {}` 를 본문 `opts = opts === void 0 ? {} : opts` 로 낮춘다. 이 세 참조를
    // 새 노드로 만들며 심볼을 물려주지 않으면, minify 가 매개변수 선언만 바꾸고 검사는
    // 원래 이름으로 남아 호출마다 ReferenceError 가 난다.
    const src =
        \\export function f(alpha, opts = { k: 2 }) { return alpha + opts.k; }
    ;
    var r = try transpile(std.testing.allocator, src, "/src/a.js", .{
        .minify_identifiers = true,
        .minify_whitespace = true,
        .es_target = .es5,
        .unsupported = @import("transformer/compat.zig").fromESTarget(.es5),
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "opts") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "===void 0?{k:2}:") != null);
}

test "#4760 es5 상태 기계가 대입·선언으로 접은 블록 바인딩도 rename 을 따라간다" {
    // 상태 기계는 `const value = …` 를 `value$1 = …` 대입으로 접고 `var value$1` 을 wrapper
    // 최상단에 올린다. 두 노드가 원래 바인딩의 심볼을 받지 못하면 minify 가 참조만 바꿔
    // `value$1=_step.value;return[4,n]` 처럼 갈라진다.
    const src =
        \\export function* gen(items) {
        \\  for (const value of items) {
        \\    const doubled = yield value;
        \\    record(doubled);
        \\  }
        \\}
    ;
    var r = try transpile(std.testing.allocator, src, "/src/a.js", .{
        .minify_identifiers = true,
        .minify_whitespace = true,
        .es_target = .es5,
        .unsupported = @import("transformer/compat.zig").fromESTarget(.es5),
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "value$") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "doubled") == null);

    // catch 파라미터·구조분해 선언은 이름만 모아 `name$N` 으로 바꾸는 경로로 올라간다.
    const src2 =
        \\export function* gen2(source) {
        \\  try { yield 1; } catch (failure) { record(failure); }
        \\  { const { first, second } = source; yield first; record(second); }
        \\}
    ;
    var r2 = try transpile(std.testing.allocator, src2, "/src/b.js", .{
        .minify_identifiers = true,
        .minify_whitespace = true,
        .es_target = .es5,
        .unsupported = @import("transformer/compat.zig").fromESTarget(.es5),
    });
    defer r2.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r2.code, "failure") == null);
    try std.testing.expect(std.mem.indexOf(u8, r2.code, "first$") == null);
    try std.testing.expect(std.mem.indexOf(u8, r2.code, "second$") == null);
}

test "#4760 es5 루프 캡처 `_loop` 의 매개변수·인자·끌어올린 var 도 rename 을 따라간다" {
    // 클로저가 헤더 let 을 캡처하면 본문을 `_loop(index)` 로 뽑는다. 매개변수·인자와 본문
    // `var` 를 바깥으로 올린 선언은 이름으로 새로 만들어져, 심볼이 없으면 minify 가 원래
    // 이름으로 찍어 `_loop(index)` 가 미선언 참조가 된다.
    const src =
        \\export function collect(limit) {
        \\  const getters = [];
        \\  for (let index = 0; index < limit; index++) {
        \\    var latest = index * 2;
        \\    getters.push(() => index + latest);
        \\  }
        \\  return getters;
        \\}
    ;
    var r = try transpile(std.testing.allocator, src, "/src/a.js", .{
        .minify_identifiers = true,
        .minify_whitespace = true,
        .es_target = .es5,
        .unsupported = @import("transformer/compat.zig").fromESTarget(.es5),
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "index") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "latest") == null);
}

test "#4759 이름 줄이기는 낮춘·접은 뒤 코드로 한다 — 새 노드도 같은 이름을 따른다" {
    // 구문 접기가 `(0, holder).n` 을 `holder.n` 으로 바꾸며 만든 새 노드는 변환 전 분석의
    // 심볼이 없다. 변환 전 스코프로 이름을 지으면 선언만 바뀌고 이 참조는 원래 이름으로 남는다.
    const src =
        \\const holder = { n() { return 1; } };
        \\console.log(typeof (0, holder).n, holder.n());
    ;
    var r = try transpile(std.testing.allocator, src, "/src/a.js", .{
        .minify_identifiers = true,
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "holder") == null);
}

test "minify 가 짓는 이름은 코드가 참조하는 전역을 가리지 않는다" {
    // 바인딩이 많으면 2글자 이름까지 간다. 코드가 전역 `ee` 를 참조하는데 바인딩 하나가
    // `ee` 로 바뀌면 그 참조가 전역 대신 지역 변수를 읽는다 (큰 파일에선 `var Set = …`).
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "export function big(seed) {\n");
    for (0..80) |i| try src.print(std.testing.allocator, "  let value{d} = seed + {d};\n", .{ i, i });
    try src.appendSlice(std.testing.allocator, "  return [");
    for (0..80) |i| try src.print(std.testing.allocator, "value{d}, ", .{i});
    try src.appendSlice(std.testing.allocator, "ee];\n}\n");

    var r = try transpile(std.testing.allocator, src.items, "/src/a.js", .{
        .minify_identifiers = true,
        .minify_whitespace = true,
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "let ee=") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "ee]") != null);
}

test "#4759 변환 뒤 재분석으로 이름을 지어도 export·클래스 식 이름은 보존한다" {
    // TS `export = Box` 는 변환 뒤 `module.exports = Box` 라 재분석에선 export 가 아니다.
    // 변환 전 분석의 "이름 보존" 판정을 재분석 심볼로 옮기지 않으면 `class t` 가 된다.
    var r = try transpile(std.testing.allocator, "class Box { v = 1; greet() { return this.v; } }\nconst helperValue = 2;\nexport = Box;\nconsole.log(helperValue);", "/src/app.ts", .{
        .minify_identifiers = true,
        .minify_whitespace = true,
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "class Box") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "module.exports=Box") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "helperValue") == null);

    // es5 는 클래스 식을 함수로 낮춰 재분석에선 클래스 식 이름이 아니다 — `.name` 이 바뀌면 안 된다.
    var r2 = try transpile(std.testing.allocator, "const Holder = class InnerName { static who() { return InnerName.name; } };\nconsole.log(Holder.who());", "/src/b.js", .{
        .minify_identifiers = true,
        .minify_whitespace = true,
        .es_target = .es5,
        .unsupported = @import("transformer/compat.zig").fromESTarget(.es5),
    });
    defer r2.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r2.code, "function InnerName(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2.code, "Holder") == null);
}

test "stage 3 데코레이터 헬퍼 호출은 minify 에서 preamble 과 같은 짧은 이름을 쓴다" {
    // minify 는 헬퍼 정의를 `$eD`·`$rI` 로 줄이는데, 데코레이터 변환이 원래 이름
    // (`__esDecorate(…)`) 으로 불러 `ReferenceError: __esDecorate is not defined` 였다.
    var r = try transpile(std.testing.allocator,
        \\function logged(value, ctx) { return value; }
        \\export class Service { @logged run() { return 1; } static total = 2; }
    , "/src/a.ts", .{
        .minify_whitespace = true,
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "__esDecorate(") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "__runInitializers(") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "$eD(") != null);
}

test "#4819 standalone helper preamble resolves its emitted name through SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "");
    defer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();

    var runtime_aliases: std.StringHashMapUnmanaged([]const u8) = .empty;
    try runtime_aliases.put(allocator, "__extends", "__extends2");
    try runtime_aliases.put(allocator, "__generator", "__generator2");
    try runtime_aliases.put(allocator, "__rest", "__rest2");
    try runtime_aliases.put(allocator, "__async", "__async2");
    try runtime_aliases.put(allocator, "__asyncValues", "__asyncValues2");
    try runtime_aliases.put(allocator, "__values", "__values2");
    try runtime_aliases.put(allocator, "__read", "__read2");
    try runtime_aliases.put(allocator, "__publicField", "__publicField2");
    try runtime_aliases.put(allocator, "__tdz", "__tdz2");
    try runtime_aliases.put(allocator, "__classCallCheck", "__classCallCheck2");
    try runtime_aliases.put(allocator, "__classPrivateMethodInit", "__classPrivateMethodInit2");
    try runtime_aliases.put(allocator, "__classPrivateMethodGet", "__classPrivateMethodGet2");
    try runtime_aliases.put(allocator, "__zntcClassPrivateFieldSet", "__zntcClassPrivateFieldSet2");
    try runtime_aliases.put(allocator, "__callSuper", "__callSuper2");
    try runtime_aliases.put(allocator, "__superGet", "__superGet2");
    try runtime_aliases.put(allocator, "__superSet", "__superSet2");
    try runtime_aliases.put(allocator, "__taggedTemplateLiteral", "__taggedTemplateLiteral2");
    try runtime_aliases.put(allocator, "__name", "__name2");
    var helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty;
    try helper_scope_map.put(allocator, "__extends2", 0);
    try helper_scope_map.put(allocator, "__generator2", 1);
    try helper_scope_map.put(allocator, "__rest2", 2);
    try helper_scope_map.put(allocator, "__async2", 3);
    try helper_scope_map.put(allocator, "__asyncValues2", 4);
    try helper_scope_map.put(allocator, "__values2", 5);
    try helper_scope_map.put(allocator, "__read2", 6);
    try helper_scope_map.put(allocator, "__taggedTemplateLiteral2", 7);
    try helper_scope_map.put(allocator, "__publicField2", 8);
    try helper_scope_map.put(allocator, "__tdz2", 9);
    try helper_scope_map.put(allocator, "__classCallCheck2", 10);
    try helper_scope_map.put(allocator, "__classPrivateMethodInit2", 11);
    try helper_scope_map.put(allocator, "__classPrivateMethodGet2", 12);
    try helper_scope_map.put(allocator, "__callSuper2", 13);
    try helper_scope_map.put(allocator, "__superGet2", 14);
    try helper_scope_map.put(allocator, "__superSet2", 15);
    try helper_scope_map.put(allocator, "__zntcClassPrivateFieldSet2", 16);
    try helper_scope_map.put(allocator, "__name2", 17);
    const helper_symbols = [_]@import("semantic/symbol.zig").Symbol{
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__extends2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__generator2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__rest2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__async2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__asyncValues2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__values2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__read2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__taggedTemplateLiteral2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__publicField2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__tdz2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__classCallCheck2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__classPrivateMethodInit2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__classPrivateMethodGet2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__callSuper2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__superGet2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__superSet2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__zntcClassPrivateFieldSet2",
        },
        .{
            .name = @import("lexer/token.zig").Span.EMPTY,
            .scope_id = .none,
            .kind = .import_binding,
            .declaration_span = @import("lexer/token.zig").Span.EMPTY,
            .synthetic_name = "__name2",
        },
    };
    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    defer transformer.deinit();
    transformer.runtime_helper_aliases = runtime_aliases;
    transformer.helper_scope_map = helper_scope_map;
    transformer.symbols = &helper_symbols;
    transformer.semantic_edit_enabled = true;

    const resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__extends", false);
    try std.testing.expectEqualStrings("__extends2", resolved);
    const generator_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__generator", false);
    try std.testing.expectEqualStrings("__generator2", generator_resolved);
    const rest_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__rest", false);
    try std.testing.expectEqualStrings("__rest2", rest_resolved);
    const async_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__async", false);
    try std.testing.expectEqualStrings("__async2", async_resolved);
    const async_values_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__asyncValues", false);
    try std.testing.expectEqualStrings("__asyncValues2", async_values_resolved);
    const values_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__values", false);
    try std.testing.expectEqualStrings("__values2", values_resolved);
    const read_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__read", false);
    try std.testing.expectEqualStrings("__read2", read_resolved);
    const public_field_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__publicField", false);
    try std.testing.expectEqualStrings("__publicField2", public_field_resolved);
    const tdz_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__tdz", false);
    try std.testing.expectEqualStrings("__tdz2", tdz_resolved);
    const class_call_check_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__classCallCheck", false);
    try std.testing.expectEqualStrings("__classCallCheck2", class_call_check_resolved);
    const private_method_init_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__classPrivateMethodInit", false);
    try std.testing.expectEqualStrings("__classPrivateMethodInit2", private_method_init_resolved);
    const private_method_get_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__classPrivateMethodGet", false);
    try std.testing.expectEqualStrings("__classPrivateMethodGet2", private_method_get_resolved);
    const call_super_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__callSuper", false);
    try std.testing.expectEqualStrings("__callSuper2", call_super_resolved);
    const super_get_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__superGet", false);
    try std.testing.expectEqualStrings("__superGet2", super_get_resolved);
    const super_set_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__superSet", false);
    try std.testing.expectEqualStrings("__superSet2", super_set_resolved);
    const private_field_set_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__classPrivateFieldSet", false);
    try std.testing.expectEqualStrings("__zntcClassPrivateFieldSet2", private_field_set_resolved);
    const tagged_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__taggedTemplateLiteral", false);
    try std.testing.expectEqualStrings("__taggedTemplateLiteral2", tagged_resolved);
    const keep_names_resolved = try standaloneRuntimeHelperSymbolName(&transformer, "__name", false);
    try std.testing.expectEqualStrings("__name2", keep_names_resolved);

    _ = transformer.helper_scope_map.remove("__extends2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__extends", false),
    );
    _ = transformer.helper_scope_map.remove("__generator2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__generator", false),
    );
    _ = transformer.helper_scope_map.remove("__rest2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__rest", false),
    );
    _ = transformer.helper_scope_map.remove("__async2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__async", false),
    );
    _ = transformer.helper_scope_map.remove("__asyncValues2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__asyncValues", false),
    );
    _ = transformer.helper_scope_map.remove("__values2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__values", false),
    );
    _ = transformer.helper_scope_map.remove("__read2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__read", false),
    );
    _ = transformer.helper_scope_map.remove("__publicField2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__publicField", false),
    );
    _ = transformer.helper_scope_map.remove("__tdz2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__tdz", false),
    );
    _ = transformer.helper_scope_map.remove("__classCallCheck2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__classCallCheck", false),
    );
    _ = transformer.helper_scope_map.remove("__classPrivateMethodInit2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__classPrivateMethodInit", false),
    );
    _ = transformer.helper_scope_map.remove("__classPrivateMethodGet2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__classPrivateMethodGet", false),
    );
    _ = transformer.helper_scope_map.remove("__callSuper2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__callSuper", false),
    );
    _ = transformer.helper_scope_map.remove("__superGet2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__superGet", false),
    );
    _ = transformer.helper_scope_map.remove("__superSet2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__superSet", false),
    );
    _ = transformer.helper_scope_map.remove("__zntcClassPrivateFieldSet2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__classPrivateFieldSet", false),
    );
    _ = transformer.helper_scope_map.remove("__taggedTemplateLiteral2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__taggedTemplateLiteral", false),
    );
    _ = transformer.helper_scope_map.remove("__name2");
    try std.testing.expectError(
        error.TransformError,
        standaloneRuntimeHelperSymbolName(&transformer, "__name", false),
    );
}

test "#4819 standalone extends preamble and call share the collision-free helper name" {
    const es5 = TranspileOptions{
        .es_target = .es5,
        .unsupported = @import("transformer/compat.zig").fromESTarget(.es5),
    };
    var r = try transpile(
        std.testing.allocator,
        "var __extends = 40; class Base {} class Child extends Base {} console.log(__extends, new Child() instanceof Base);",
        "input.js",
        es5,
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "var __extends = 40") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "var __extends2 = function") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "__extends2(Child, _super)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "__extends(Child, _super)") == null);

    var minified_options = es5;
    minified_options.minify_whitespace = true;
    var minified = try transpile(
        std.testing.allocator,
        "var $eX = 40; class Base {} class Child extends Base {} console.log($eX, new Child() instanceof Base);",
        "input.js",
        minified_options,
    );
    defer minified.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, minified.code, "var $eX=40") != null);
    try std.testing.expect(std.mem.indexOf(u8, minified.code, "var $eX2=function") != null);
    try std.testing.expect(std.mem.indexOf(u8, minified.code, "$eX2(Child,_super)") != null);
    try std.testing.expect(std.mem.indexOf(u8, minified.code, "$eX(Child,_super)") == null);
}

test "#4760 es5 블록 스코핑은 심볼로 충돌을 판정한다 (#4758 · #4764 · 매개변수)" {
    const es5 = TranspileOptions{
        .es_target = .es5,
        .unsupported = @import("transformer/compat.zig").fromESTarget(.es5),
    };
    // #4758: 함수 본문 var 와 같은 이름의 블록 let — 합치면 바깥 x 를 덮는다.
    var r1 = try transpile(std.testing.allocator, "export function f() { var x = 0; { let x = 1; g(x); } return x; }", "/src/a.js", es5);
    defer r1.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r1.code, "var x$") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.code, "var x = 0;") != null);

    // #4764: switch case 의 let 과 바깥 같은 이름.
    var r2 = try transpile(std.testing.allocator, "const value = 'outer'; export function f(k) { switch (k) { case 0: let value = 'zero'; g(value); } return value; }", "/src/b.js", es5);
    defer r2.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r2.code, "var value$") != null);

    // 매개변수와 같은 이름의 루프 변수 — var 가 되면 매개변수를 덮는다.
    var r3 = try transpile(std.testing.allocator, "export function f(key, items) { for (const key of items) g(key); return key; }", "/src/c.js", es5);
    defer r3.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r3.code, "key$") != null);

    // 형제 루프의 같은 이름은 클로저에 안 잡히면 합친다 — 불필요하게 바꾸지 않는다.
    var r4 = try transpile(std.testing.allocator, "export function f(n) { for (let i = 0; i < n; i++) g(i); for (let i = 0; i < n; i++) g(i); }", "/src/d.js", es5);
    defer r4.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r4.code, "i$") == null);
}

test "#4493 `undefined` 바인딩에 void 0 peephole 이 새지 않는다" {
    // 이 노드는 대입 대상인데도 tag 가 identifier_reference 라, value 위치를 무조건
    // emitNode 로 태우면 `undefined` → `void 0` peephole 이 발동한다.
    // `{undefined:void 0=1}` 은 대입 대상이 될 수 없어 **번들 전체가 SyntaxError** 다.
    // (`({undefined = 1} = o)` 는 문법상 합법 — 런타임에 read-only 전역 대입으로 실패할 뿐.)
    const src =
        \\function f(o) {
        \\  ({ undefined = 1 } = o);
        \\}
    ;
    var r = try transpile(std.testing.allocator, src, "/src/a.js", .{
        .minify_identifiers = true,
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "void 0=") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "undefined:undefined=1") != null);
}

test "#4493 rename 이 없으면 shorthand+기본값 출력은 그대로 (회귀 0)" {
    // mangler 를 끄면 value 위치도 원본 이름이므로 emit 이 바뀌지 않아야 한다.
    const src =
        \\function f(o) {
        \\  let stackWeight;
        \\  ({ stackWeight = 1 } = o);
        \\  return stackWeight;
        \\}
    ;
    var r = try transpile(std.testing.allocator, src, "/src/a.js", .{
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "stackWeight:stackWeight=1") != null);
}

// ================================================================
// #4515 — #4493 잔여 4건 (전부 별개 루트커즈)
// ================================================================

test "#4515 `{ undefined }` 객체 리터럴 shorthand 가 `{void 0}` 로 새지 않는다" {
    // shorthand 는 노드 **하나**가 프로퍼티 이름(키)이자 값이다. 값 쪽 peephole
    // (`undefined` → `void 0`)이 발동하면 키 자리에 `void 0` 이 앉아 `{void 0}` →
    // 번들 전체가 SyntaxError. 치환이 걸리면 longhand 로 펼쳐 키를 원본으로 고정해야 한다.
    const src =
        \\export const o = { undefined };
    ;
    var r = try transpile(std.testing.allocator, src, "/src/a.js", .{
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer r.deinit(std.testing.allocator);
    // 버그 시: `{void 0}` (SyntaxError)
    try std.testing.expect(std.mem.indexOf(u8, r.code, "{void 0}") == null);
    // 키는 원본 이름으로 보존 + 값만 치환 → `{undefined:void 0}`
    try std.testing.expect(std.mem.indexOf(u8, r.code, "undefined:void 0") != null);
}

test "#4515 정상 객체 리터럴 shorthand 는 확장되지 않는다 (회귀 0)" {
    // 치환이 없으면 shorthand 유지 — 무조건 펼치면 size 회귀다.
    const src =
        \\export function f(alpha, beta) { return { alpha, beta }; }
    ;
    var r = try transpile(std.testing.allocator, src, "/src/a.js", .{
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "{alpha,beta}") != null);
}

test "#4515 `({undefined = 1} = o)` 대입 대상에는 peephole 이 발동하지 않는다" {
    // 대입 대상 자리인데 태그는 `identifier_reference` 라, 값 전용 치환을 그대로 태우면
    // `{undefined:void 0=1}` — 대입 대상이 될 수 없어 SyntaxError.
    // (`({undefined = 1} = o)` 는 문법상 합법 — 런타임 TypeError 일 뿐이다.)
    const src =
        \\export function f(o) { ({ undefined = 1 } = o); }
    ;
    var r = try transpile(std.testing.allocator, src, "/src/a.js", .{
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "void 0=") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "undefined:undefined=1") != null);
}

test "#4515 패턴의 computed key 가 semantic 참조로 잡힌다 (DCE 방지)" {
    // analyzer 가 패턴 프로퍼티의 computed key(`[k]`)를 방문하지 않아 `k` 에 읽기 참조가
    // 안 잡혔다 → DCE/const-inline 이 선언을 지우는데 codegen 은 key 를 원본 이름으로
    // 내보낸다 → ReferenceError. 여기서는 `k` 가 **사용된 것으로** 집계돼 rename 이
    // 키 안쪽까지 따라오는지로 관측한다.
    const src =
        \\export function f(o) {
        \\  const someKeyName = "kk";
        \\  let target;
        \\  ({ [someKeyName]: target = 1 } = o);
        \\  return target;
        \\}
    ;
    var r = try transpile(std.testing.allocator, src, "/src/a.js", .{
        .minify_identifiers = true,
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer r.deinit(std.testing.allocator);
    // computed key 안의 식별자가 rename 을 따라가야 한다 — 원본 이름이 남아 있으면
    // 참조가 안 잡혀 선언만 지워지는(또는 리네임 불일치) 상태다.
    try std.testing.expect(std.mem.indexOf(u8, r.code, "[someKeyName]") == null);
}

test "#4515 선언형 패턴의 computed key 도 동일 (let/const predeclare 경로)" {
    // let/const 는 predeclare 경로라 registerBinding 을 안 타고
    // visitBindingPatternExpressions 로 빠진다 — 거기에도 computed key 방문이 필요하다.
    const src =
        \\export function f(o) {
        \\  const someKeyName = "kk";
        \\  const { [someKeyName]: target } = o;
        \\  return target;
        \\}
    ;
    var r = try transpile(std.testing.allocator, src, "/src/a.js", .{
        .minify_identifiers = true,
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "[someKeyName]") == null);
}

test "#4392 refresh hook-sig: long signature (>1024B) not truncated/aborted" {
    // hook 이 많은 컴포넌트는 signature 문자열이 1024바이트를 넘는다. 과거
    // buildRefreshSigCall 의 고정 [1024]u8 버퍼는 초과 시 가짜 OOM 으로 transpile
    // 전체를 중단시켰다.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try src.appendSlice(std.testing.allocator, "function App() {\n");
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        var line: [40]u8 = undefined;
        const s = try std.fmt.bufPrint(&line, "  useHookNumber{d}();\n", .{i});
        try src.appendSlice(std.testing.allocator, s);
    }
    try src.appendSlice(std.testing.allocator, "  return null;\n}\n");

    var r = try transpile(std.testing.allocator, src.items, "/src/App.tsx", .{
        .react_refresh = true,
        .react_refresh_hook_signatures = true,
    });
    defer r.deinit(std.testing.allocator);
    // 가짜 OOM abort 없이 signature 전체(마지막 hook 포함)가 emit 되어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, r.code, "$RefreshSig$") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.code, "useHookNumber119") != null);
}

// ============================================================
// #4481 — `return`/`throw` 직후 *괄호 안* 주석의 line terminator (ASI)
// ============================================================
//
// paren 이 투명해진(#4042) 뒤 `return ( /*c*/ g() )` 의 첫 출력 토큰은 `g` 다. 그런데
// 주석 flush 기준을 래퍼 span(`(` 위치)으로 잡으면 괄호 *안* 주석이 안 걸리고, 나중에
// emitComments 가 newline + indent 와 함께 출력한다 → `return` 은 ASI 로 끝나 undefined 를
// 반환하고(빌드 green, 값만 틀림) `throw` 는 `Illegal newline after throw` 로 죽는다.
// minify 없이도 재현되며, codegen 유닛 하네스는 주석을 배선하지 않아 여기서 가드한다.

test "#4481 return/throw 직후 괄호 안 주석은 inline (ASI 방지)" {
    var result = try transpileWithCallbackInternal(
        std.testing.allocator,
        "function f(g) { return ( /* inner */ g() ); }\nfunction h(g) { throw ( /* inner */ new Error(g) ); }\n",
        "input.js",
        .{},
        null,
        true,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "return /* inner */ g()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "throw /* inner */ new Error") != null);
    // 줄바꿈이 keyword 와 operand 사이에 끼면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, result.code, "return /* inner */\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "throw /* inner */\n") == null);
}

// ============================================================
// #4482 — AST 미니파이어가 노드 태그를 바꾼 뒤의 load-bearing 괄호
// ============================================================
//
// `minify_syntax` 는 상수를 인라인하고 `-a` 를 **numeric_literal("-2")** 로 접는다.
// 그 순간 codegen 의 `exprNeedsParens` 가 보던 `.unary_expression` 태그가 사라져
// `.prefix` 이상 슬롯의 필수 괄호가 유실됐다 (`-2**2` = SyntaxError,
// `-2 .toString()` = 값이 문자열이 아닌 숫자 — silent). 폴딩은 transpile 레이어에서
// 일어나 codegen 유닛 하네스로는 재현되지 않으므로 여기서 가드한다.
// (`!0`/`void 0` peephole 은 codegen 레벨이라 load_bearing_paren.zig 가 커버.)

fn expectMinifiedCodeContains(source: []const u8, needle: []const u8) !void {
    var result = try transpileWithCallbackInternal(
        std.testing.allocator,
        source,
        "input.js",
        .{ .minify_syntax = true, .minify_whitespace = true },
        null,
        true,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    if (std.mem.indexOf(u8, result.code, needle) == null) {
        std.debug.print("\n#4482: \"{s}\" 가 출력에 없음:\n{s}\n", .{ needle, result.code });
        return error.LoadBearingParenLost;
    }
}

test "#4482 minify: 폴딩된 음수 리터럴이 ** 좌측이면 괄호" {
    // `-2**2` 는 SyntaxError — `**` 좌변에 단항이 직접 올 수 없다.
    try expectMinifiedCodeContains("const a = 2; g((-a) ** 2);", "(-2)**2");
}

test "#4482 minify: 폴딩된 음수 리터럴이 member object 면 괄호" {
    // `-2 .toString()` 은 `-(2 .toString())` 로 파싱된다 — 문자열 "-2" 가 아니라 숫자 -2.
    // 빌드는 통과하고 런타임 값만 틀리는 silent miscompile.
    try expectMinifiedCodeContains("const a = 2; g((-a).toString());", "(-2).toString");
}

test "#4482 minify: 음수 리터럴이 call callee / new callee 면 괄호" {
    try expectMinifiedCodeContains("const a = 2; g((-a)());", "(-2)()");
}

test "#4482 minify: 폴딩된 음수 리터럴 앞 단항 부호는 공백으로 끊는다" {
    // `--2` 는 prefix 감소 연산으로 오파싱 → SyntaxError (리터럴은 lvalue 가 아님).
    try expectMinifiedCodeContains("const a = 2; g(-(-a));", "- -2");
}

test "#4482 minify: 과잉 괄호 방지 — 양수 리터럴은 그대로" {
    // needle 이 `4`/`8` 이면 `(4)`/`(8)` 에도 매치해 과잉 괄호를 못 잡는다 → 호출 형태로 고정.
    try expectMinifiedCodeContains("const a = 2; g(a ** 2);", "g(4)");
    try expectMinifiedCodeContains("g(2 ** 3);", "g(8)");
    try expectMinifiedCodeContains("g(-(+t));", "g(-+t)");
    try expectMinifiedCodeContains("g(a ** -b);", "g(a**-b)");
    // 괄호로 감싸이는 피연산자 앞에는 공백을 넣지 않는다 (`- (-a-b)` 가 아니라 `-(-a-b)`).
    try expectMinifiedCodeContains("g(-(-a - b));", "g(-(-a-b))");
    try expectMinifiedCodeContains("g(a - (-b - a));", "g(a-(-b-a))");
    // `<<` 는 maximal-munch 로 먼저 떨어져 `<!--` 가 생기지 않는다 → 공백 불필요.
    try expectMinifiedCodeContains("g(x << !--b);", "g(x<<!--b)");
}
