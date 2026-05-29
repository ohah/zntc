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
const TransformOptions = @import("transformer/transformer.zig").TransformOptions;
const BindingLite = @import("transformer/transformer.zig").BindingLite;
const Codegen = @import("codegen/codegen.zig").Codegen;
const SourceMap = @import("codegen/sourcemap.zig");
const Mangler = @import("codegen/mod.zig").mangler;
const module_parser = @import("parser/module.zig");
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
    /// class / private / decorator / TS 런타임 구문 (`enum`, `namespace`, `import =`,
    /// `export =`, `namespace export`) / `using` — runtime transform 필요.
    has_runtime_sensitive_syntax: bool = false,
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

/// `prefix` 가 null/빈 문자열이면 `body` 그대로, 아니면 `prefix + body` 의 새 buffer 반환.
/// OOM 시 fallback 으로 body 그대로 반환 (transpile output 보존). JSX/cssProp 의 module-level
/// import auto-inject 둘 다 같은 모양이라 공유.
fn prependImportLine(allocator: std.mem.Allocator, prefix: ?[]const u8, body: []const u8) []const u8 {
    const p = prefix orelse return body;
    if (p.len == 0) return body;
    var combined: std.ArrayList(u8) = .empty;
    combined.ensureTotalCapacity(allocator, p.len + body.len) catch return body;
    combined.appendSliceAssumeCapacity(p);
    combined.appendSliceAssumeCapacity(body);
    return combined.items;
}

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

            .class_declaration,
            .class_expression,
            .private_identifier,
            .private_field_expression,
            .decorator,
            .ts_enum_declaration,
            .ts_module_declaration,
            .ts_import_equals_declaration,
            .ts_export_assignment,
            .ts_namespace_export_declaration,
            => facts.has_runtime_sensitive_syntax = true,

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
    if (idx.isNone()) return false;
    const node = ast.getNode(idx);
    switch (node.tag) {
        .function_declaration,
        .function_expression,
        .function,
        .arrow_function_expression,
        => return false,
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
        },
        else => {},
    }

    var it = ast_walk.children(ast, node);
    while (it.next()) |child_idx| {
        if (try walkFunctionVarBindingPatterns(ast, child_idx, ctx, onBindingPattern)) return true;
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

fn scanChildrenForUnsupportedBindingLiteShadow(
    ast: *const Ast,
    node: ast_mod.Node,
    names: []const []const u8,
    child_scope_depth: usize,
    inside_function: bool,
    fn_shadow_count: ?*usize,
) error{OutOfMemory}!bool {
    var it = ast_walk.children(ast, node);
    while (it.next()) |child_idx| {
        if (try scanForUnsupportedBindingLiteShadow(ast, child_idx, names, child_scope_depth, inside_function, fn_shadow_count)) return true;
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

/// Babel `preset-typescript` 의 자동 type-only export elision 을 모든 변환 경로에서
/// 재현. transformer 의 `.export_specifier` 디스패치가 SPEC_FLAG_TYPE_ONLY 비트를 보고
/// 자동 drop 하므로, 비트만 일관되게 마킹하면 .none / .bindings / .full 모두 동일 출력.
///
/// **호출 시점**: `SemanticAnalyzer.analyze()` 호출 전. .full 경로의 analyzer 가
/// 마킹된 비트를 보고 specifier 검증을 skip 한다. .none / .bindings 도 동일 비트 기반.
///
/// **두 패스**:
///   pass 1 (top-level statement walk): value binding name (var/let/const/function/class
///   /enum, import default/namespace/named-value) 과 type-only binding name (type alias,
///   interface, import-type specifier) 을 각각 set 에 수집. declaration merging
///   (`const X = 1; type X = ...;`) 처리를 위해 value 가 type 보다 우선.
///   pass 2 (export_named_declaration scan): source 없는 `export { x }` 의 specifier
///   중 local 이 value_names 에 없고 type_only_names 에 있는 것만 비트 OR.
///
/// 재-export (`export { x } from './y'`) 는 로컬 binding 과 무관 → skip.
/// `export { 'name' }` string literal local 도 식별자가 아니라 skip.
fn markAutoTypeOnlyExportSpecifiers(
    allocator: std.mem.Allocator,
    ast: *Ast,
) error{OutOfMemory}!void {
    // program 의 top-level statements 만 본다. ES module spec: export 는 모듈 scope
    // binding 만 reference. nested function 의 local var/type alias 는 export 와 무관.
    var program_idx: ast_mod.NodeIndex = .none;
    for (ast.nodes.items, 0..) |node, raw_idx| {
        if (node.tag == .program) {
            program_idx = @enumFromInt(raw_idx);
            break;
        }
    }
    if (program_idx.isNone()) return;
    const prog_node = ast.getNode(program_idx);
    const stmt_start = prog_node.data.list.start;
    const stmt_len = prog_node.data.list.len;
    if (stmt_len == 0) return;

    var value_names: std.StringHashMapUnmanaged(void) = .empty;
    defer value_names.deinit(allocator);
    var type_only_names: std.StringHashMapUnmanaged(void) = .empty;
    defer type_only_names.deinit(allocator);

    // pass 1
    var i: u32 = 0;
    while (i < stmt_len) : (i += 1) {
        const stmt_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[stmt_start + i]);
        if (stmt_idx.isNone()) continue;
        if (@intFromEnum(stmt_idx) >= ast.nodes.items.len) continue;
        try collectAutoTypeOnlyDeclNames(allocator, ast, stmt_idx, &value_names, &type_only_names);
    }

    // ast.declare_only_names: top-level `declare class/function/var/...` 는 parser 가
    // strip 해 AST 에 없지만, 이름 자체는 parser 가 사이드테이블에 등록 (D13). value-only
    // binding 으로 분류되지 않는 type-only binding 으로 취급.
    if (type_only_names.count() == 0 and ast.declare_only_names.count() == 0) return;

    // pass 2
    for (ast.nodes.items) |node| {
        if (node.tag != .export_named_declaration) continue;
        const extra_start = node.data.extra;
        const extras = ast.extra_data.items;
        if (extra_start + 3 >= extras.len) continue;
        const specs_start = extras[extra_start + 1];
        const specs_len = extras[extra_start + 2];
        const source_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra_start + 3]);
        if (!source_idx.isNone()) continue;
        if (specs_len == 0 or specs_start + specs_len > extras.len) continue;

        const spec_indices = extras[specs_start .. specs_start + specs_len];
        for (spec_indices) |raw_idx| {
            const spec_idx: ast_mod.NodeIndex = @enumFromInt(raw_idx);
            if (spec_idx.isNone()) continue;
            if (@intFromEnum(spec_idx) >= ast.nodes.items.len) continue;
            const spec_node = ast.getNode(spec_idx);
            if (spec_node.tag != .export_specifier) continue;
            if ((spec_node.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) continue;

            const local_idx = spec_node.data.binary.left;
            if (local_idx.isNone()) continue;
            if (@intFromEnum(local_idx) >= ast.nodes.items.len) continue;
            const local_node = ast.getNode(local_idx);
            if (local_node.tag == .string_literal) continue;

            const local_name = ast.getText(local_node.span);
            // declaration merging: 동명의 value binding 이 있으면 type-only 마킹 skip.
            // `const X = 1; type X = ...; export { X };` 또는
            // `class A {}; declare class A; export { A };` 양쪽에서 value 우선.
            if (value_names.contains(local_name)) continue;
            if (type_only_names.contains(local_name) or
                ast.declare_only_names.contains(local_name))
            {
                ast.setBinaryFlags(spec_idx, spec_node.data.binary.flags | module_parser.SPEC_FLAG_TYPE_ONLY);
            }
        }
    }
}

/// `markAutoTypeOnlyExportSpecifiers` pass 1 의 statement-level 분기. top-level
/// program statement 한 개를 처리.
fn collectAutoTypeOnlyDeclNames(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    stmt_idx: ast_mod.NodeIndex,
    value_names: *std.StringHashMapUnmanaged(void),
    type_only_names: *std.StringHashMapUnmanaged(void),
) error{OutOfMemory}!void {
    const stmt = ast.getNode(stmt_idx);
    switch (stmt.tag) {
        // value bindings: function / class / enum — extras[0] = name
        .function_declaration,
        .class_declaration,
        .ts_enum_declaration,
        => try putNameAtExtraSlot(allocator, ast, stmt, 0, value_names),

        // ts_module_declaration: binary layout — binary.left = name (namespace) 또는
        // string_literal (declare module "..."). 후자는 binding 이름이 아니라 skip.
        .ts_module_declaration => {
            const name_idx = stmt.data.binary.left;
            if (name_idx.isNone()) return;
            if (@intFromEnum(name_idx) >= ast.nodes.items.len) return;
            const name_node = ast.getNode(name_idx);
            if (name_node.tag == .string_literal) return;
            try putNodeIdName(allocator, ast, name_idx, value_names);
        },

        // import X = require(...) — runtime value
        .ts_import_equals_declaration => {
            // binary: left=name, right=value
            const left = stmt.data.binary.left;
            try putNodeIdName(allocator, ast, left, value_names);
        },

        // variable_declaration: destructuring 포함 모든 binding identifier 추출.
        // extras = [kind_flags, list_start, list_len]
        .variable_declaration => {
            const list_start = ast.extra_data.items[stmt.data.extra + 1];
            const list_len = ast.extra_data.items[stmt.data.extra + 2];
            var j: u32 = 0;
            while (j < list_len) : (j += 1) {
                const decl_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[list_start + j]);
                if (decl_idx.isNone()) continue;
                const decl = ast.getNode(decl_idx);
                if (decl.tag != .variable_declarator) continue;
                // variable_declarator extras[0] = binding pattern (또는 simple identifier)
                const binding_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[decl.data.extra]);
                try collectBindingIdentifierNames(allocator, ast, binding_idx, value_names);
            }
        },

        // type-only declarations
        .ts_type_alias_declaration,
        .ts_interface_declaration,
        => try putNameAtExtraSlot(allocator, ast, stmt, 0, type_only_names),

        // import declaration: type-only spec / inline `type X` 는 type_only_names,
        // 나머지 (default / namespace / named-value) 는 value_names
        .import_declaration => {
            const decl = module_parser.readImportDeclExtras(ast, stmt.data.extra);
            var j: u32 = 0;
            while (j < decl.specs_len) : (j += 1) {
                const spec_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[decl.specs_start + j]);
                if (spec_idx.isNone()) continue;
                if (@intFromEnum(spec_idx) >= ast.nodes.items.len) continue;
                const spec = ast.getNode(spec_idx);
                switch (spec.tag) {
                    // import_specifier: binary { left=imported, right=local }
                    .import_specifier => {
                        const local_idx = spec.data.binary.right;
                        if (local_idx.isNone()) continue;
                        const is_type_only = decl.is_type_only or
                            (spec.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0;
                        const bucket = if (is_type_only) type_only_names else value_names;
                        try putNodeIdName(allocator, ast, local_idx, bucket);
                    },
                    // import_default_specifier / import_namespace_specifier: 파서가 local
                    // 이름을 spec_node.span (string_ref) 에 직접 저장 — 별도 name 노드
                    // 없음 (module.zig parseImportClause). codegen/analyzer 와 동일하게
                    // span 텍스트로 읽는다 (D13 layout: 이전엔 extra_data 인덱스로 오독).
                    .import_default_specifier, .import_namespace_specifier => {
                        const name_text = ast.getText(spec.span);
                        if (name_text.len == 0) continue;
                        const bucket = if (decl.is_type_only) type_only_names else value_names;
                        try bucket.put(allocator, name_text, {});
                    },
                    else => {},
                }
            }
        },

        // export declaration 안의 nested decl 도 처리 (export const / type / interface / ...).
        // extras = [decl, specs_start, specs_len, source, ...]
        .export_named_declaration => {
            const extra_start = stmt.data.extra;
            if (extra_start >= ast.extra_data.items.len) return;
            const decl_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra_start]);
            if (decl_idx.isNone()) return;
            if (@intFromEnum(decl_idx) >= ast.nodes.items.len) return;
            // 재귀 분기 — declaration 자체의 binding 만 등록 (specifier 는 pass 2 에서 처리)
            try collectAutoTypeOnlyDeclNames(allocator, ast, decl_idx, value_names, type_only_names);
        },

        else => {},
    }
}

fn putNameAtExtraSlot(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    node: ast_mod.Node,
    slot: u32,
    bucket: *std.StringHashMapUnmanaged(void),
) error{OutOfMemory}!void {
    const extra_start = node.data.extra;
    if (extra_start + slot >= ast.extra_data.items.len) return;
    const name_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra_start + slot]);
    try putNodeIdName(allocator, ast, name_idx, bucket);
}

fn putNodeIdName(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    name_idx: ast_mod.NodeIndex,
    bucket: *std.StringHashMapUnmanaged(void),
) error{OutOfMemory}!void {
    if (name_idx.isNone()) return;
    if (@intFromEnum(name_idx) >= ast.nodes.items.len) return;
    const name_node = ast.getNode(name_idx);
    const name_text = ast.getText(name_node.span);
    if (name_text.len == 0) return;
    try bucket.put(allocator, name_text, {});
}

/// binding pattern (identifier / array / object pattern) 안의 모든 binding identifier
/// 텍스트를 bucket 에 모은다. `const { a: b, c = 1, ...rest } = x;` 같은 destructuring
/// 도 b / c / rest 가 value binding.
fn collectBindingIdentifierNames(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    idx: ast_mod.NodeIndex,
    bucket: *std.StringHashMapUnmanaged(void),
) error{OutOfMemory}!void {
    if (idx.isNone()) return;
    if (@intFromEnum(idx) >= ast.nodes.items.len) return;
    var it = try ast_walk.bindingIdentifiers(ast.allocator, ast, idx, .{ .cover_grammar_assignment = false });
    defer it.deinit();
    while (try it.next()) |leaf_idx| {
        const leaf = ast.getNode(leaf_idx);
        const name = ast.getText(leaf.span);
        if (name.len > 0) try bucket.put(allocator, name, {});
    }
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
    if (idx.isNone()) return;
    const node = ast.getNode(idx);

    if (Transformer.isTypeOnlyNode(node.tag) or node.tag.isTypeOnlyDeclaration()) return;

    switch (node.tag) {
        .identifier_reference,
        .assignment_target_identifier,
        => {
            if (value_context) markBindingLiteUse(lite, ast.getText(node.span), shadowed_names);
            return;
        },
        .binding_identifier,
        .import_declaration,
        .import_specifier,
        .import_default_specifier,
        .import_namespace_specifier,
        .import_attribute,
        => return,
        .block_statement,
        .function_body,
        => {
            try markBindingLiteBlockScope(ast, node, lite, shadowed_names);
            return;
        },
        .catch_clause => {
            var shadow_buf: [binding_lite_max_shadows][]const u8 = undefined;
            var shadow_len: usize = 0;
            for (shadowed_names) |name| appendBindingLiteShadowName(&shadow_buf, &shadow_len, name);
            try collectBindingLitePatternShadows(ast, node.data.binary.left, lite, &shadow_buf, &shadow_len);
            try markBindingLiteValueUses(ast, node.data.binary.right, lite, true, shadow_buf[0..shadow_len]);
            return;
        },
        .try_statement => {
            try markBindingLiteValueUses(ast, node.data.ternary.a, lite, true, shadowed_names);
            try markBindingLiteValueUses(ast, node.data.ternary.b, lite, true, shadowed_names);
            try markBindingLiteValueUses(ast, node.data.ternary.c, lite, true, shadowed_names);
            return;
        },
        .export_specifier => {
            try markBindingLiteValueUses(ast, node.data.binary.left, lite, true, shadowed_names);
            return;
        },
        .export_named_declaration => {
            const x = module_parser.readExportNamedExtras(ast, node.data.extra);
            try markBindingLiteValueUses(ast, x.decl, lite, true, shadowed_names);
            try markBindingLiteListValueUses(ast, .{ .start = x.specs_start, .len = x.specs_len }, lite, true, shadowed_names);
            return;
        },
        .variable_declaration => {
            const list_start = ast.extra_data.items[node.data.extra + 1];
            const list_len = ast.extra_data.items[node.data.extra + 2];
            try markBindingLiteListValueUses(ast, .{ .start = list_start, .len = list_len }, lite, true, shadowed_names);
            return;
        },
        .variable_declarator => {
            try markBindingPatternDefaultValueUses(ast, @enumFromInt(ast.extra_data.items[node.data.extra]), lite, shadowed_names);
            try markBindingLiteValueUses(ast, @enumFromInt(ast.extra_data.items[node.data.extra + 2]), lite, true, shadowed_names);
            return;
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
            return;
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
            return;
        },
        .formal_parameters => {
            try markBindingLiteListValueUses(ast, node.data.list, lite, false, shadowed_names);
            return;
        },
        .assignment_pattern,
        .assignment_target_with_default,
        => {
            try markBindingLiteValueUses(ast, node.data.binary.left, lite, false, shadowed_names);
            try markBindingLiteValueUses(ast, node.data.binary.right, lite, true, shadowed_names);
            return;
        },
        // `(Foo = Bar()) =>` 같이 cover-grammar 로 패턴 자리에 남은 assignment_expression 은
        // value_context=false (formal_parameters 진입) 에서만 LHS=binding/RHS=value 로 쪼갠다.
        // expression context (`Foo = expr;`) 는 LHS 가 assignment_target_identifier 라 default
        // child walk 로 그대로 value_context=true 가 전파돼야 import 가 use 마킹된다.
        .assignment_expression => {
            if (!value_context) {
                try markBindingLiteValueUses(ast, node.data.binary.left, lite, false, shadowed_names);
                try markBindingLiteValueUses(ast, node.data.binary.right, lite, true, shadowed_names);
                return;
            }
        },
        .formal_parameter => {
            const e = node.data.extra;
            try markBindingPatternDefaultValueUses(ast, @enumFromInt(ast.extra_data.items[e]), lite, shadowed_names);
            try markBindingLiteValueUses(ast, @enumFromInt(ast.extra_data.items[e + 2]), lite, true, shadowed_names);
            return;
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
            return;
        },
        .static_member_expression,
        .private_field_expression,
        => {
            try markBindingLiteValueUses(ast, @enumFromInt(ast.extra_data.items[node.data.extra]), lite, true, shadowed_names);
            return;
        },
        else => {},
    }

    var it = ast_walk.children(ast, node);
    while (it.next()) |child_idx| {
        try markBindingLiteValueUses(ast, child_idx, lite, value_context, shadowed_names);
    }
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
    _ = parser.parse() catch return error.ParseError;
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
        try markAutoTypeOnlyExportSpecifiers(arena_alloc, &parser.ast);
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

    // 3. Identifier mangling (--minify-identifiers)
    var mangle_result: ?Mangler.ManglerResult = null;
    defer if (mangle_result) |*mr| mr.deinit();

    if (options.minify_identifiers) {
        const analyzer = &(analyzer_storage.?);
        if (analyzer.symbols.items.len > 0 and analyzer.scope_maps.items.len > 0) {
            mangle_result = Mangler.mangle(arena_alloc, .{
                .scopes = analyzer.scopes.items,
                .symbols = analyzer.symbols.items,
                .scope_maps = analyzer.scope_maps.items,
                .references = analyzer.references.items,
                .source = source,
            }) catch null;
        }
    }

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
    var transformer = try Transformer.initFromOwnedAst(arena_alloc, &parser.ast, effective_opts);
    if (analyzer_storage) |*analyzer| {
        transformer.initSymbolIds(analyzer.symbol_ids.items) catch return error.TransformError;
        transformer.symbols = analyzer.symbols.items;
        transformer.references = analyzer.references.items;
    } else if (binding_lite_storage) |*binding_lite| {
        transformer.binding_lite = binding_lite;
    }
    transformer.line_offsets = scanner.line_offsets.items;
    const root = transformer.transform() catch return error.TransformError;
    mem_profile.snap(&arena, "transform");

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
        minify_mod.mergeDecls(transformer.ast, null);
    }

    // 5. Mangling 메타데이터 구성. skip_nodes는 arena-owned이라 별도 deinit 불필요
    // (함수 종료 시 arena.deinit으로 일괄 해제).
    var mangle_metadata: ?LinkingMetadata = null;

    if (mangle_result) |*mr| {
        const node_count = transformer.ast.nodes.items.len;
        mangle_metadata = .{
            .skip_nodes = std.DynamicBitSet.initEmpty(arena_alloc, node_count) catch return error.OutOfMemory,
            .renames = mr.renames,
            .final_exports = null,
            .symbol_ids = if (transformer.symbol_ids.items.len > 0)
                transformer.symbol_ids.items
            else
                &.{},
            // 단일 파일 transpile: codegen 의 scope-hoisted 전용 분기를 타지 않도록 false.
            .is_bundle_context = false,
            .allocator = arena_alloc,
        };
    }

    // 6. 코드 생성
    var cg = Codegen.initWithOptions(arena_alloc, transformer.ast, .{
        .module_format = options.module_format,
        .minify_whitespace = options.minify_whitespace,
        .minify_syntax = options.minify_syntax,
        .sourcemap = options.sourcemap,
        .ascii_only = if (options.charset_utf8) false else options.ascii_only,
        .quote_style = options.quote_style,
        .linking_metadata = if (mangle_metadata) |*mm| mm else null,
        .platform = options.platform,
        .source_root = options.source_root,
        .sources_content = options.sources_content,
        .strip_hashbang = options.unsupported.hashbang,
        .assert_no_raw_private_syntax = options.unsupported.requiresPrivateDownlevel(),
        // JSX: Transformer가 이미 call_expression으로 lowering 완료. codegen에 JSX 옵션 불필요.
    });
    cg.comments = scanner.comments.items;
    if (options.sourcemap) {
        cg.addSourceFile(file_path) catch {};
        cg.line_offsets = scanner.line_offsets.items;
    }
    const raw_output = cg.generate(root) catch return error.CodegenError;
    mem_profile.snap(&arena, "generate");

    // 6.5. JSX import prepend (transformer가 JSX lowering 수행한 경우).
    // transformer.options 는 per-file pragma (#D026) 가 적용된 effective 설정 — 원본
    // `options.jsx_*` 가 아니라 이쪽을 써야 `@jsxImportSource` / `@jsxRuntime` 가 반영된다.
    const jsx_import_str: ?[]const u8 = if (transformer.jsx_import_info.hasImports()) blk: {
        const is_dev = transformer.options.jsx_runtime == .automatic_dev;
        break :blk transformer.jsx_import_info.buildImportString(arena_alloc, transformer.options.jsx_import_source, is_dev);
    } else null;
    const jsx_output = prependImportLine(arena_alloc, jsx_import_str, raw_output);

    // 6.6. styled-components cssProp auto-inject — 사용자 코드에 styled import 가 없는데
    // cssProp transform 이 일어난 경우 program 시작에 styled import 추가. binding 이름은
    // collision detection 후 결정된 `css_prop_inject_name` 사용.
    const css_prop_import: ?[]const u8 = if (transformer.plugins.styled_components.css_prop_needs_import) blk: {
        const name = transformer.plugins.styled_components.css_prop_inject_name;
        break :blk std.fmt.allocPrint(arena_alloc, "import {s} from \"styled-components\";\n", .{name}) catch null;
    } else null;
    const css_prop_output = prependImportLine(arena_alloc, css_prop_import, jsx_output);

    // 7. 런타임 헬퍼 prepend
    const rh = transformer.runtime_helpers;
    const has_helpers = rh.hasAny();
    const output = if (has_helpers) blk: {
        var buf: std.ArrayList(u8) = .empty;
        rt.appendRuntimeHelpers(&buf, arena_alloc, rh, options.minify_whitespace, transformer.runtime_es5_compat) catch
            break :blk css_prop_output;
        buf.appendSlice(arena_alloc, css_prop_output) catch break :blk css_prop_output;
        break :blk buf.items;
    } else css_prop_output;

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
        try function_expression_overflow_source.writer(std.testing.allocator).print(", I{d}", .{j});
    }
    try function_expression_overflow_source.appendSlice(std.testing.allocator, " } from './x';\nconst fn = function Foo(");
    j = 0;
    while (j < 64) : (j += 1) {
        try function_expression_overflow_source.writer(std.testing.allocator).print("I{d},", .{j});
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
        try overflow_source.writer(std.testing.allocator).print(" I{d},", .{i});
    }
    try overflow_source.appendSlice(std.testing.allocator, " } from './x';\nfunction f(");
    i = 0;
    while (i < 65) : (i += 1) {
        try overflow_source.writer(std.testing.allocator).print("I{d},", .{i});
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

// D13: top-level `declare class/function/var` 의 name 은 type-only binding.
// `export { X as Y };` 가 declare 만 reference 하면 specifier 가 자동 elide (Babel
// preset-typescript 동작). parser 가 top-level declare 를 strip 해 AST 에 사라지므로
// markAutoTypeOnlyExportSpecifiers 가 별도 sideband (`ast.declare_only_names`) 에서
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
