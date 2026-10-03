//! ModuleGraph transformer pre-pass and post-transform metadata resync helpers.

const std = @import("std");
const Module = @import("../module.zig").Module;
const ModuleSemanticData = @import("../module.zig").ModuleSemanticData;
const AliasTable = @import("../module.zig").AliasTable;
const binding_scanner_mod = @import("../binding_scanner.zig");
const bundler_symbol = @import("../symbol.zig");
const import_scanner = @import("../import_scanner.zig");
const stmt_info_mod = @import("../stmt_info.zig");
const purity = @import("../purity.zig");
const profile = @import("../../profile.zig");
const ast_mod = @import("../../parser/ast.zig");
const ast_walk = @import("../../parser/ast_walk.zig");
const module_parser = @import("../../parser/module.zig");
const token_mod = @import("../../lexer/token.zig");
const NodeTag = ast_mod.Node.Tag;
const SemanticSymbol = @import("../../semantic/symbol.zig").Symbol;
const SemanticSymbolKind = @import("../../semantic/symbol.zig").SymbolKind;
const SemanticAnalyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
const isTypeOnlyNode = @import("../../transformer/transformer/type_only.zig").isTypeOnlyNode;
const Transformer = @import("../../transformer/transformer.zig").Transformer;
const TransformOptions = @import("../../transformer/transformer.zig").TransformOptions;
const builtin_plugins = @import("../../transformer/plugins/builtin.zig");
const Span = @import("../../lexer/token.zig").Span;
const parse_helpers = @import("parse_helpers.zig");
const injectFlowEnumRuntimeImport = @import("synthetic_imports.zig").injectFlowEnumRuntimeImport;
const symbol_coverage_env = @import("../../env_flag.zig").Once("ZNTC_DEBUG_SYMBOL_COVERAGE");

const isFlowPath = parse_helpers.isFlowPath;
const suppressRuntimeHelperInternalUnresolved = parse_helpers.suppressRuntimeHelperInternalUnresolved;
const mergeImportRecords = parse_helpers.mergeImportRecords;
const projectExportedNames = parse_helpers.projectExportedNames;
const determineExportsKind = parse_helpers.determineExportsKind;

/// Capture the exact binding that owns the promise returned by TLA lowering.
/// The emitter adds a wait/return after ordinary AST codegen, so it needs this
/// binding's semantic identity instead of searching the generated source text.
fn tlaPromiseReference(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    stmt_idx: ast_mod.NodeIndex,
) ?Module.TlaPromiseReference {
    const stmt_raw = @intFromEnum(stmt_idx);
    if (stmt_idx.isNone() or stmt_raw >= ast.nodes.items.len) return null;
    const stmt = ast.nodes.items[stmt_raw];
    if (stmt.tag != .variable_declaration) return null;

    const extra = stmt.data.extra;
    if (extra + 2 >= ast.extra_data.items.len) return null;
    const list_start = ast.extra_data.items[extra + 1];
    const list_len = ast.extra_data.items[extra + 2];
    if (list_len != 1 or list_start >= ast.extra_data.items.len) return null;

    const decl_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[list_start]);
    if (decl_idx.isNone() or @intFromEnum(decl_idx) >= ast.nodes.items.len) return null;
    const decl = ast.nodes.items[@intFromEnum(decl_idx)];
    if (decl.tag != .variable_declarator or decl.data.extra >= ast.extra_data.items.len) return null;
    const binding_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[decl.data.extra]);
    if (binding_idx.isNone() or @intFromEnum(binding_idx) >= ast.nodes.items.len) return null;
    if (ast.nodes.items[@intFromEnum(binding_idx)].tag != .binding_identifier) return null;

    const binding_raw = @intFromEnum(binding_idx);
    if (binding_raw >= semantic.symbol_ids.len) return null;
    const symbol_raw = semantic.symbol_ids[binding_raw] orelse return null;
    if (symbol_raw >= semantic.symbols.items.len) return null;
    const symbol = semantic.symbols.items[symbol_raw];
    if (symbol.scope_id.isNone()) return null;

    return .{
        .binding_node_index = binding_raw,
        .symbol_id = @enumFromInt(symbol_raw),
        .scope_id = symbol.scope_id,
    };
}

fn refreshTlaPromiseReference(module: *Module) void {
    module.tla_promise_reference = null;
    const stmt_raw = module.tla_iife_stmt orelse return;
    const ast = &(module.ast orelse return);
    const semantic = &(module.semantic orelse return);
    module.tla_promise_reference = tlaPromiseReference(ast, semantic, @enumFromInt(stmt_raw));
}

/// 보수적 graph pre-pass 게이트.
///
/// graph 단계 pre-pass 는 helper/runtime import 를 link 전에 발견해야 하는 모듈에만
/// 필요하다. 단순 ESM/TS-strip 모듈은 parser scan + semantic 결과를 그대로 쓰고,
/// emit 단계의 legacy transformer/codegen 경로가 최종 출력 변환을 수행한다.
pub fn shouldRun(
    self: anytype,
    module: *const Module,
    plugin_transform_applied: bool,
) bool {
    {
        var gate_scope = profile.begin(.graph_discover_pm_prepass_decision_module_gate);
        defer gate_scope.end();
        if (!module.module_type.isJavaScriptLike()) return false;
        if (plugin_transform_applied) return true;

        // Check cheap single-byte flags before the heavier option predicate.
        if (self.minify_identifiers) return true;
        // react_refresh / styled-components / emotion 은 emitter·`run` 과 마찬가지로 user
        // code 에만 적용된다 (`/node_modules/` 밖). node_modules 의 plain ESM/ES5 dep 까지
        // pre-pass 를 돌리던 게 가장 큰 낭비였다 — 그 모듈들은 helper import 도 안 만든다.
        const is_user_code = std.mem.indexOf(u8, module.path, "/node_modules/") == null;
        if (is_user_code and (self.react_refresh or self.styled_components or self.emotion)) return true;
        // worklet 변환은 react-native / @react-native 코어를 제외한 모든 모듈 대상 (`run` 의
        // exclude_worklet 과 동일). 워크릿 디렉티브가 없으면 plugin 은 no-op 이지만, 변환이
        // helper 를 주입할 수 있으니 게이트는 보수적으로 유지.
        if (self.worklet_transform) {
            const is_rn_core = std.mem.indexOf(u8, module.path, "/node_modules/react-native/") != null or
                std.mem.indexOf(u8, module.path, "/node_modules/@react-native/") != null;
            if (!is_rn_core) return true;
        }
    }

    const ast = &module.ast.?;
    {
        var ast_flags_scope = profile.begin(.graph_discover_pm_prepass_decision_ast_flags);
        defer ast_flags_scope.end();
        if (ast.has_jsx or ast.has_decorator or ast.has_ts_namespace_or_enum or
            ast.has_ts_import_equals or ast.has_ts_export_equals)
        {
            return true;
        }
    }

    {
        var options_scope = profile.begin(.graph_discover_pm_prepass_decision_options);
        defer options_scope.end();
        return self.transform_options_base.requiresGraphPrePass(ast);
    }
}

/// Type erasure and Flow match lowering are local to the parsed module body.
/// For the restricted no-plugin/no-helper case, the transform editor already
/// carries the exact binding/reference/scope graph. Keep this predicate
/// deliberately narrow: runtime Flow extensions, import rewriting, JSX,
/// runtime helpers, and semantic-changing transforms continue through the
/// full resync path.
const FlowMatchGeneratedGlobals = struct {
    has_match: bool = false,
    array: bool = false,
    object: bool = false,
};

fn flowMatchGeneratedGlobals(ast: *const ast_mod.Ast) FlowMatchGeneratedGlobals {
    var globals: FlowMatchGeneratedGlobals = .{};
    for (ast.nodes.items) |node| {
        switch (node.tag) {
            .flow_match_expression => globals.has_match = true,
            .flow_match_array_pattern => globals.array = true,
            .flow_match_object_pattern => {
                const list = node.data.list;
                for (0..list.len) |i| {
                    const child_raw = ast.extra_data.items[list.start + i];
                    const child = ast.getNode(@enumFromInt(child_raw));
                    if (child.tag == .flow_match_rest and child.data.none == 1) {
                        globals.object = true;
                        break;
                    }
                }
            },
            else => {},
        }
    }
    return globals;
}

fn addGeneratedGlobal(
    allocator: std.mem.Allocator,
    semantic: *ModuleSemanticData,
    name: []const u8,
) !void {
    if (semantic.unresolved_references.contains(name)) return;
    const stable_name = try allocator.dupe(u8, name);
    errdefer allocator.free(stable_name);
    try semantic.unresolved_references.put(allocator, stable_name, {});
}

/// Flow match array/object-rest lowering emits these free references without
/// parser nodes. The full analyzer normally discovers them after lowering;
/// when keeping the editor graph, preserve the same linker reservation facts.
fn addFlowMatchGeneratedGlobals(
    allocator: std.mem.Allocator,
    semantic: *ModuleSemanticData,
    globals: FlowMatchGeneratedGlobals,
) !void {
    if (globals.array) try addGeneratedGlobal(allocator, semantic, "Array");
    if (globals.object) try addGeneratedGlobal(allocator, semantic, "Object");
}

fn fallbackToFullSemanticResync(self: anytype, module: *Module, arena_alloc: std.mem.Allocator) bool {
    resyncAfterAstMutation(self, module, arena_alloc, null) catch {
        self.addDiag(
            .parse_error,
            .@"error",
            module.path,
            Span.EMPTY,
            .parse,
            "Post-transform analysis refresh failed",
            "The transformed AST could not be re-analyzed safely.",
        );
        module.state = .ready;
        return false;
    };
    return true;
}

fn isTypeErasureTag(tag: NodeTag) bool {
    return isTypeOnlyNode(tag) or ast_mod.Node.Tag.isTransparentTypeWrapper(tag);
}

fn isSupportedRuntimeTsEnum(ast: *const ast_mod.Ast, node: ast_mod.Node) bool {
    if (node.tag != .ts_enum_declaration) return false;
    const extra = node.data.extra;
    if (extra >= ast.extra_data.items.len or ast.extra_data.items.len - extra <= 3) return false;
    // Only ordinary runtime enums retain the same AST and semantic edges.
    // Const and ambient enums are erased or inlined by the transformer.
    return ast.extra_data.items[extra + 3] == 0;
}

/// Keeping the semantic graph is safe only when the transform leaves each
/// runtime import's module-graph shape unchanged. Ordinary unused named
/// imports can be elided, and inline type-only specifiers can be removed, so
/// this first slice admits runtime imports only under verbatim syntax and
/// without inline type-only specifiers. Declaration-level type imports have
/// no runtime import record and are always erased.
fn hasStableRuntimeImports(ast: *const ast_mod.Ast, options: TransformOptions) bool {
    for (ast.nodes.items) |node| {
        if (node.tag != .import_declaration) continue;
        const import = module_parser.readImportDeclExtras(ast, node.data.extra);
        if (import.is_type_only) continue;
        if (import.phase != .none or import.attrs_len != 0) return false;
        if (import.specs_len == 0) continue;
        if (!options.verbatim_module_syntax) return false;
        if (import.specs_start > ast.extra_data.items.len or
            import.specs_len > ast.extra_data.items.len - import.specs_start) return false;

        for (ast.extra_data.items[import.specs_start .. import.specs_start + import.specs_len]) |raw_spec_idx| {
            if (raw_spec_idx >= ast.nodes.items.len) return false;
            const specifier = ast.nodes.items[raw_spec_idx];
            switch (specifier.tag) {
                .import_default_specifier, .import_namespace_specifier => {},
                .import_specifier => {
                    if ((specifier.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) return false;
                },
                else => return false,
            }
        }
    }
    return true;
}

/// Source-less export lists at the program root retain local references and
/// rebuild export bindings from the transformed AST. Re-exports, namespace
/// exports, and string export names require the full graph resync path.
fn hasOnlyTopLevelLocalExportSpecifiers(module: *const Module) bool {
    const ast = &(module.ast orelse return false);
    const semantic = &(module.semantic orelse return false);
    var specifier_count: usize = 0;
    for (ast.nodes.items) |node| {
        if (node.tag == .export_specifier) specifier_count += 1;
    }
    if (specifier_count == 0) return true;
    if (ast.nodes.items.len == 0) return false;

    const root_idx = ast.transformed_root orelse @as(
        ast_mod.NodeIndex,
        @enumFromInt(@as(u32, @intCast(ast.nodes.items.len - 1))),
    );
    if (root_idx.isNone() or @intFromEnum(root_idx) >= ast.nodes.items.len) return false;
    const root = ast.getNode(root_idx);
    if (root.tag != .program) return false;

    const extras = ast.extra_data.items;
    const statements = root.data.list;
    if (statements.start > extras.len or statements.len > extras.len - statements.start) return false;

    var safe_specifier_count: usize = 0;
    for (extras[statements.start .. statements.start + statements.len]) |raw_stmt_idx| {
        if (raw_stmt_idx >= ast.nodes.items.len) return false;
        const statement = ast.getNode(@enumFromInt(raw_stmt_idx));
        if (statement.tag != .export_named_declaration) continue;

        const extra_start = statement.data.extra;
        if (extra_start > extras.len or extras.len - extra_start < 6) return false;
        const export_decl = module_parser.readExportNamedExtras(ast, extra_start);
        if (export_decl.specs_len == 0) continue;
        if (!export_decl.decl.isNone()) return false;
        if (!export_decl.source.isNone()) return false;
        if (export_decl.specs_start > extras.len or
            export_decl.specs_len > extras.len - export_decl.specs_start) return false;

        for (extras[export_decl.specs_start .. export_decl.specs_start + export_decl.specs_len]) |raw_spec_idx| {
            if (raw_spec_idx >= ast.nodes.items.len) return false;
            const specifier = ast.getNode(@enumFromInt(raw_spec_idx));
            if (specifier.tag != .export_specifier) return false;
            if ((specifier.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) {
                safe_specifier_count += 1;
                continue;
            }

            const local_idx = specifier.data.binary.left;
            if (local_idx.isNone() or @intFromEnum(local_idx) >= ast.nodes.items.len) return false;
            if (ast.getNode(local_idx).tag != .identifier_reference) return false;

            const local_raw = @intFromEnum(local_idx);
            if (local_raw >= semantic.symbol_ids.len) return false;
            const symbol_id = semantic.symbol_ids[local_raw] orelse return false;
            if (symbol_id >= semantic.symbols.items.len) return false;
            switch (semantic.symbols.items[symbol_id].kind) {
                .variable_var,
                .variable_let,
                .variable_const,
                .function_decl,
                .generator_decl,
                .async_function_decl,
                .async_generator_decl,
                .class_decl,
                => {},
                else => return false,
            }

            const exported_idx = specifier.data.binary.right;
            if (!exported_idx.isNone()) {
                if (@intFromEnum(exported_idx) >= ast.nodes.items.len) return false;
                if (ast.getNode(exported_idx).tag != .identifier_reference) return false;
            }
            safe_specifier_count += 1;
        }
    }

    return safe_specifier_count == specifier_count;
}

fn hasDirectSpreadElement(ast: *const ast_mod.Ast, node: ast_mod.Node) bool {
    var children = ast_walk.children(ast, node);
    while (children.next()) |child_idx| {
        if (child_idx.isNone() or @intFromEnum(child_idx) >= ast.nodes.items.len) continue;
        if (ast.nodes.items[@intFromEnum(child_idx)].tag == .spread_element) return true;
    }
    return false;
}

/// The arrow lowering path edits the existing graph and creates only output
/// function scopes plus its explicitly tracked lexical captures. Keep the
/// retained-graph path for this narrowly audited JavaScript subset; an
/// unrecognized node or parameter form stays on the full semantic resync path.
fn canRetainGraphForArrowOnlyLowering(ast: *const ast_mod.Ast, options: TransformOptions) bool {
    if (!options.unsupported.arrow or ast.has_jsx) return false;

    // Cover-grammar parsing may leave speculative nodes in the arena that are
    // not part of the program. Only reachable syntax can affect this lowering.
    if (ast.nodes.items.len == 0) return false;
    const root_idx = ast.transformed_root orelse @as(
        ast_mod.NodeIndex,
        @enumFromInt(@as(u32, @intCast(ast.nodes.items.len - 1))),
    );
    if (root_idx.isNone() or @intFromEnum(root_idx) >= ast.nodes.items.len or
        ast.getNode(root_idx).tag != .program) return false;
    const reachable_nodes = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, root_idx) catch return false;
    defer ast.allocator.free(reachable_nodes);

    var found_arrow = false;
    for (reachable_nodes) |raw_idx| {
        const node = ast.nodes.items[raw_idx];
        // Type erasure already edits the semantic graph through the same
        // transform-aware path; its nodes add no runtime scopes or bindings.
        if (isTypeErasureTag(node.tag)) continue;
        switch (node.tag) {
            .arrow_function_expression => {
                const flags_at = node.data.extra + ast_mod.ArrowExtra.flags;
                if (flags_at >= ast.extra_data.items.len) return false;
                if ((ast.extra_data.items[flags_at] & ast_mod.ArrowFlags.is_async) != 0) return false;
                found_arrow = true;
            },
            .function_declaration, .function_expression, .function => {
                const flags_at = node.data.extra + ast_mod.FunctionExtra.flags;
                if (flags_at >= ast.extra_data.items.len) return false;
                const flags = ast.extra_data.items[flags_at];
                if ((flags & (ast_mod.FunctionFlags.is_async | ast_mod.FunctionFlags.is_generator)) != 0)
                    return false;
            },
            .variable_declaration => {
                if (ast.variableDeclarationKind(node) != .@"var") return false;
            },
            .variable_declarator => {
                if (node.data.extra >= ast.extra_data.items.len) return false;
                const binding: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[node.data.extra]);
                if (binding.isNone() or @intFromEnum(binding) >= ast.nodes.items.len or
                    ast.nodes.items[@intFromEnum(binding)].tag != .binding_identifier) return false;
            },
            .formal_parameter => {
                const extra = node.data.extra;
                if (extra + 2 >= ast.extra_data.items.len) return false;
                const pattern: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra]);
                const default_value: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra + 2]);
                if (pattern.isNone() or @intFromEnum(pattern) >= ast.nodes.items.len or
                    ast.nodes.items[@intFromEnum(pattern)].tag != .binding_identifier or !default_value.isNone()) return false;
            },
            .assignment_expression => {
                const operator: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                if (options.unsupported.exponentiation and operator == .star2_eq) return false;
                if (options.unsupported.logical_assignment and
                    (operator == .question2_eq or operator == .pipe2_eq or operator == .amp2_eq)) return false;
            },
            .binary_expression, .logical_expression => {
                const operator: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                if (node.tag == .binary_expression and options.unsupported.exponentiation and
                    operator == .star2) return false;
                if (node.tag == .logical_expression and options.unsupported.nullish_coalescing and
                    operator == .question2) return false;
            },
            .array_expression, .call_expression, .new_expression => {
                if (options.unsupported.spread and hasDirectSpreadElement(ast, node)) return false;
            },
            .object_expression => {
                // Object spread has its own target feature. Include ordinary
                // spread conservatively for explicit/custom feature masks.
                if ((options.unsupported.spread or options.unsupported.object_spread) and
                    hasDirectSpreadElement(ast, node)) return false;
            },
            .computed_property_key => {
                // Native computed object keys only wrap their expression in the
                // AST. Downleveling them can hoist key evaluation into generated
                // temporaries, which still requires semantic reanalysis.
                if (options.unsupported.object_extensions) return false;
            },
            // This allowlist deliberately leaves module graph edits and all
            // other downlevel families on the existing resync path.
            .program,
            .boolean_literal,
            .null_literal,
            .numeric_literal,
            // BigInt literals are copied verbatim and add no semantic graph edges.
            .bigint_literal,
            .string_literal,
            // Regex lowering rewrites only the literal payload. Helper-producing
            // named-capture cases still fall back after transform below.
            .regexp_literal,
            .this_expression,
            .identifier_reference,
            // Plain identifier writes use this reference tag and are already
            // tracked as writes in the semantic graph. Destructuring targets
            // keep their separate, intentionally unlisted pattern tags.
            .assignment_target_identifier,
            .binding_identifier,
            .object_property,
            .conditional_expression,
            .template_literal,
            .template_element,
            .unary_expression,
            .update_expression,
            .computed_member_expression,
            .static_member_expression,
            // Parent-specific checks above keep transformed spread forms on
            // semantic reanalysis; native spread elements preserve the graph.
            .spread_element,
            .parenthesized_expression,
            .block_statement,
            .empty_statement,
            .expression_statement,
            .if_statement,
            .switch_statement,
            .switch_case,
            .while_statement,
            .do_while_statement,
            .for_statement,
            .for_in_statement,
            .break_statement,
            .continue_statement,
            .return_statement,
            .throw_statement,
            .try_statement,
            .catch_clause,
            .labeled_statement,
            .debugger_statement,
            .directive,
            .hashbang,
            .formal_parameters,
            .function_body,
            .sequence_expression,
            => {},
            else => return false,
        }
        if (node.tag == .catch_clause and node.data.binary.left.isNone()) return false;
    }
    return found_arrow;
}

fn canKeepPrepassSemanticGraph(
    self: anytype,
    module: *const Module,
    options: TransformOptions,
    plugins: anytype,
) bool {
    if (module.ast == null or module.semantic == null) return false;
    const ast = &module.ast.?;
    if (self.worklet_transform or self.react_refresh or self.styled_components or self.emotion or
        self.plugins.len != 0 or plugins.len != 0 or options.plugins.len != 0) return false;
    if (!options.strip_types) return false;
    const classic_jsx = ast.has_jsx and options.jsx_transform and options.jsx_runtime == .classic;
    const automatic_jsx = ast.has_jsx and options.jsx_transform and options.jsx_runtime == .automatic;
    const automatic_dev_jsx = ast.has_jsx and options.jsx_transform and options.jsx_runtime == .automatic_dev;
    const graph_editable_jsx = classic_jsx or automatic_jsx or automatic_dev_jsx;
    const arrow_only_downlevel = options.unsupported.hasAny() and
        canRetainGraphForArrowOnlyLowering(ast, options);
    if ((ast.has_jsx and !graph_editable_jsx) or ast.has_decorator or ast.has_ts_import_equals or
        ast.has_ts_export_equals or ast.has_flow_enum_declaration) return false;
    if ((options.unsupported.hasAny() and !arrow_only_downlevel) or options.minify_syntax or
        options.minify_whitespace or options.drop_console or options.drop_debugger or
        options.drop_labels.len != 0 or options.define.len != 0 or options.module_specifier_map.len != 0 or
        !options.use_define_for_class_fields or options.experimental_decorators or
        options.emit_decorator_metadata or options.tla_chunk_wrapped or options.tla_export_decl_deferrable) return false;
    if (module.uses_top_level_await or module.self_uses_top_level_await) return false;
    if (!hasOnlyTopLevelLocalExportSpecifiers(module)) return false;
    if (!hasStableRuntimeImports(ast, options)) return false;

    var found_transform = graph_editable_jsx or arrow_only_downlevel;
    for (ast.nodes.items) |node| {
        const tag_name = @tagName(node.tag);
        const is_flow_match_tag = std.mem.startsWith(u8, tag_name, "flow_match_");
        if (std.mem.startsWith(u8, tag_name, "flow_") and !is_flow_match_tag and
            !isTypeErasureTag(node.tag)) return false;
        if (isTypeErasureTag(node.tag)) found_transform = true;
        switch (node.tag) {
            .flow_match_expression => found_transform = true,
            // These constructs can alter the import/export graph or create
            // dynamic-name environments independently of Flow match lowering.
            .export_all_declaration,
            .ts_import_equals_declaration,
            .ts_export_assignment,
            .ts_namespace_export_declaration,
            .await_expression,
            .yield_expression,
            .with_statement,
            => return false,
            // Runtime import module-graph stability was proven by the preflight
            // above; declaration-level type imports have no runtime record.
            .import_declaration => {},
            .ts_enum_declaration => {
                if (!isSupportedRuntimeTsEnum(ast, node)) return false;
                found_transform = true;
            },
            .ts_module_declaration => {
                if (node.data.binary.flags != 0) return false;
                found_transform = true;
            },
            .identifier_reference => {
                const name = ast.getText(node.span);
                // Escaped identifiers can decode to `eval` while their source
                // spelling differs. Keep all escaped references on the full
                // resync path instead of risking a missed direct-eval scope.
                if (std.mem.eql(u8, name, "eval") or std.mem.indexOfScalar(u8, name, '\\') != null) return false;
            },
            else => {},
        }
    }
    return found_transform;
}

fn printPrepassExact(
    allocator: std.mem.Allocator,
    module: *const Module,
    root: @import("../../parser/ast.zig").NodeIndex,
    parser_node_count: u32,
    transformer: *const Transformer,
    unresolved_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    pre_transform_scope_count: usize,
    retained_graph: bool,
) !void {
    const sem = if (module.semantic) |*value| value else return;
    const ast = &(module.ast orelse return);
    const helper_refs = if (module.transform_cache) |cache| cache.helper_ref_nodes else &.{};
    const coverage = @import("../../transformer/symbol_coverage.zig");
    const exact = try coverage.checkExactWithNamespaceMetadata(
        allocator,
        ast,
        root,
        parser_node_count,
        sem.symbol_ids,
        sem.symbols.items,
        sem.scopes,
        sem.scope_maps,
        &sem.scope_owner_map,
        sem.references,
        helper_refs,
        &sem.helper_scope_map,
        unresolved_nodes,
        &transformer.explicit_global_reference_nodes,
        &transformer.reference_origin_map,
        &sem.namespace_member_owners,
        &sem.namespace_declaration_owners,
        pre_transform_scope_count,
    );
    coverage.printExactPrepass(module.path, exact, retained_graph);
}

fn auditPrepassExactIfEnabled(
    allocator: std.mem.Allocator,
    module: *const Module,
    root: ast_mod.NodeIndex,
    parser_node_count: u32,
    transformer: *const Transformer,
    unresolved_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    pre_transform_scope_count: usize,
    enabled: bool,
    retained_graph: bool,
) void {
    if (!enabled) return;
    printPrepassExact(
        allocator,
        module,
        root,
        parser_node_count,
        transformer,
        unresolved_nodes,
        pre_transform_scope_count,
        retained_graph,
    ) catch |err| {
        // An absent report must be distinguishable from a clean report. The
        // integration gate treats this diagnostic as a failure.
        std.debug.print("zntc: symbol-identity-prepass-error {s}: {s}\n", .{ module.path, @errorName(err) });
    };
}

fn collectParserUnresolvedNodes(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    parser_node_count: u32,
    symbol_ids: []const ?u32,
    unresolved_references: *const std.StringHashMapUnmanaged(void),
    unresolved_nodes: *std.AutoHashMapUnmanaged(u32, void),
) !void {
    const parser_len = @min(@as(usize, parser_node_count), ast.nodes.items.len);
    for (ast.nodes.items[0..parser_len], 0..) |node, raw| {
        if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;
        if (raw >= symbol_ids.len or symbol_ids[raw] != null) continue;
        if (!unresolved_references.contains(ast.getText(node.span))) continue;
        try unresolved_nodes.put(allocator, @intCast(raw), {});
    }
}

/// transformer pre-pass — graph 단계에서 1회 실행.
/// 결과: `module.ast` 를 transformer 결과 AST 로 교체, `module.transform_cache` set,
/// final AST 기준 분석 데이터 refresh.
/// 실패 시 error diagnostic 을 남기고 모듈 파싱을 중단한다. stale semantic/binding
/// 데이터로 tree-shaker/linker 가 진행하는 silent bug 를 막기 위한 정책 (#1913).
pub fn run(self: anytype, module: *Module, arena_alloc: std.mem.Allocator) void {
    if (module.ast == null) return;
    const ast_ptr = &(module.ast.?);

    // emitter 와 동일한 옵션 결정 휴리스틱 — 결과 분기 시 cache mismatch.
    const is_user_code = std.mem.indexOf(u8, module.path, "/node_modules/") == null;
    // worklet 변환은 react-native/@react-native 코어 제외, 나머지 node_modules 포함.
    const exclude_worklet = self.worklet_transform and
        (std.mem.indexOf(u8, module.path, "/node_modules/react-native/") != null or
            std.mem.indexOf(u8, module.path, "/node_modules/@react-native/") != null);
    const merged_plugins = builtin_plugins.collect(.{
        .worklet = self.worklet_transform and !exclude_worklet,
    }, self.plugins, arena_alloc) catch return;

    const parser_node_count: u32 = @intCast(ast_ptr.nodes.items.len);

    var opts = self.transform_options_base;
    opts.react_refresh = self.react_refresh and is_user_code;
    opts.styled_components = self.styled_components and is_user_code;
    opts.styled_components_ssr = self.styled_components_ssr;
    opts.styled_components_minify = self.styled_components_minify;
    opts.styled_components_file_name = self.styled_components_file_name;
    opts.styled_components_pure = self.styled_components_pure;
    opts.styled_components_namespace = self.styled_components_namespace;
    opts.styled_components_meaningless_file_names = self.styled_components_meaningless_file_names;
    opts.styled_components_top_level_import_paths = self.styled_components_top_level_import_paths;
    opts.styled_components_css_prop = self.styled_components_css_prop;
    opts.emotion = self.emotion and is_user_code;
    opts.emotion_auto_label = self.emotion_auto_label;
    opts.emotion_source_map = self.emotion_source_map;
    opts.emotion_label_format = self.emotion_label_format;
    opts.emotion_extra_css_sources = self.emotion_extra_css_sources;
    opts.emotion_extra_styled_sources = self.emotion_extra_styled_sources;
    opts.plugins = merged_plugins;
    opts.jsx_transform = ast_ptr.has_jsx;
    opts.jsx_filename = module.path;
    // per-file JSX pragma (D026): `@jsxRuntime` / `@jsx` / `@jsxFrag` / `@jsxImportSource`
    // 가 tsconfig/CLI 보다 우선. lowering 전에 module 의 effective JSX 설정을 확정.
    opts = opts.withModuleJsxPragmas(ast_ptr);
    if (opts.jsxClassicPragmaIgnoredUnderAutomatic(ast_ptr)) {
        self.addDiag(.jsx_pragma_ignored, .warning, module.path, Span.EMPTY, .parse, TransformOptions.jsx_pragma_ignored_msg, null);
    }
    // #1961 PR 1h 후 splitting / single-bundle 양쪽에서 helper module virtual import
    // 모델 활성. mangler 가 helper module top-level 식별자를 reserved 처리
    // (linker.zig 의 candidates collect 에서 isVirtualId 분기) — cross-module binding
    // 안전. dev mode 모듈도 동일.
    opts.emit_runtime_helper_imports = true;

    const can_keep_semantic_graph = canKeepPrepassSemanticGraph(self, module, opts, merged_plugins);
    const flow_match_generated_globals = flowMatchGeneratedGlobals(ast_ptr);
    const debug_symbol_coverage = symbol_coverage_env.enabled();
    const pre_transform_scope_count = if (module.semantic) |*sem| sem.scopes.len else 0;

    var transformer = Transformer.init(arena_alloc, ast_ptr, opts) catch return;
    transformer.record_explicit_global_references = flow_match_generated_globals.has_match;

    if (module.semantic) |*sem| {
        transformer.initSymbolIds(sem.symbol_ids) catch return;
        transformer.symbols = sem.symbols.items;
        transformer.references = sem.references;
        // 심볼 기준 블록 스코핑 표(#4760)용 — 스코프가 없으면 예전 이름 스택으로 판정한다.
        transformer.scopes = sem.scopes;
        transformer.scope_maps = sem.scope_maps;
        transformer.scope_owner_map = sem.scope_owner_map;
        transformer.class_self_symbol_map = sem.class_self_symbol_map;
        transformer.helper_scope_map = sem.helper_scope_map;
        transformer.semantic_edit_enabled = true;
        transformer.unresolved_references = &sem.unresolved_references;
    }
    transformer.line_offsets = module.line_offsets;

    var unresolved_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unresolved_nodes.deinit(arena_alloc);
    if (debug_symbol_coverage) {
        if (module.semantic) |*sem| {
            collectParserUnresolvedNodes(
                arena_alloc,
                ast_ptr,
                parser_node_count,
                sem.symbol_ids,
                &sem.unresolved_references,
                &unresolved_nodes,
            ) catch return;
            transformer.synthetic_idents = .empty;
            transformer.unresolved_reference_nodes = &unresolved_nodes;
        }
    }

    // #4598: 청크에 위임한 경우, **변환 전** AST 에서 TLA 유무를 확인해 전용 필드에 남긴다.
    // 변환 뒤에 도는 analyzer 로는 알 수 없고(그 변환이 await 를 없앤다), 전역
    // `uses_top_level_await` 를 넓히면 다른 경로가 함께 바뀐다(4차 회귀 원인).
    if (opts.tla_chunk_wrapped and opts.unsupported.top_level_await) {
        const es2022_tla_mod = @import("../../transformer/es2022_tla.zig");
        if (ast_ptr.nodes.items.len > 0) {
            const root_idx: @import("../../parser/ast.zig").NodeIndex = @enumFromInt(ast_ptr.nodes.items.len - 1);
            module.tla_delegated_to_chunk = es2022_tla_mod.hasTopLevelAwait(ast_ptr, root_idx) catch false;
        }
    }

    const root = transformer.transform() catch return;
    if (transformer.finishSemanticEdit() catch return) |edited| {
        module.semantic.?.applyEdit(edited);
        transformer.symbols = module.semantic.?.symbols.items;
        transformer.references = module.semantic.?.references;
        transformer.scopes = module.semantic.?.scopes;
        transformer.scope_maps = module.semantic.?.scope_maps;
        transformer.scope_owner_map = module.semantic.?.scope_owner_map;
        transformer.class_self_symbol_map = module.semantic.?.class_self_symbol_map;
        transformer.helper_scope_map = module.semantic.?.helper_scope_map;
    }
    // #4598: `lowerProgram` 이 만든 async IIFE statement 를 module 로 넘긴다 —
    // emitter 가 `__esm` factory 안에서 그 문장만 `return <expr>;` 로 방출한다.
    if (transformer.tla_iife_stmt) |ix| {
        module.tla_iife_stmt = @intFromEnum(ix);
        module.tla_promise_reference = null;
    }
    // #4210: 다운레벨 못한 ES2025 inline modifier 가 출력에 보존됨 → loud 진단
    // (transform-driven — 실제 fold bail 반영). transpile path 와 동일 메시지.
    if (transformer.used_unsupported_modifier) {
        self.addDiag(.regex_modifier_unsupported, .warning, module.path, Span.EMPTY, .parse, TransformOptions.regex_modifier_unsupported_msg, null);
    }
    if (self.ignore_annotations) {
        purity.clearPureCallFlags(transformer.ast);
    } else {
        purity.markUserPureCalls(transformer.ast, self.pure);
    }
    // prepass minify 의 cascade ref decrement 결과 hydrate 용 (#3267 N-step4b).
    // minify 안에서 alloc 하던 ref_deltas 를 parse_arena 에 미리 잡아 외부 소유로
    // 만들어, transform_cache 에 같은 backing 을 store. emitter minify 가 이 결과를
    // 복사 후 hydrate → prepass 에서 fold 된 dead branch 안 ref 감산이 emitter 의
    // dead-store pass 에 전파되어 cascade dead binding 도 elide 가능.
    var prepass_ref_deltas: []u32 = &.{};
    if (self.transform_options_base.minify_syntax) {
        const minify_mod = @import("../../transformer/minify.zig");
        // This flag controls top-level constant/function inlining, not
        // module-level dead-store removal. `MinifyCtx.allow_top_level_dead`
        // remains false here; top-level pruning is owned by the resynced
        // tree-shaker/emitter path.
        const allow_top_level_inline = true;
        var ctx: minify_mod.MinifyCtx = if (module.semantic != null)
            minify_mod.MinifyCtx.fromSemantic(&module.semantic.?, transformer.symbol_ids.items, allow_top_level_inline)
        else
            .empty;
        if (ctx.hasSemantic()) {
            if (arena_alloc.alloc(u32, ctx.symbols.len)) |buf| {
                @memset(buf, 0);
                prepass_ref_deltas = buf;
                ctx.ref_deltas = buf;
            } else |_| {}
        }
        minify_mod.minify(transformer.ast, ctx, arena_alloc, root);
    }

    // transformer 가 새 ast (clone) 에 transform 결과를 보유. module.ast 를 그 새 ast 로
    // swap. arena_alloc 가 owner 라 backing 은 안전. emit 단계 transformer 가 module.ast
    // 를 clone 시 transformed_root 까지 복사되어 cache hit 분기 즉시 return.
    module.ast = transformer.ast.*;

    // Temporary bridge until the final name planner consumes transformed
    // SymbolIds directly. The ES5 named-class producers record only their
    // emitted constructor bindings; preserving unrelated class names can affect
    // tree shaking after semantic resync.
    const owned_preserved_class_names = transformer.preserved_simple_class_names.toOwnedSlice(arena_alloc) catch return;
    const owned_symbol_ids = transformer.symbol_ids.toOwnedSlice(arena_alloc) catch &[_]?u32{};
    // #2869 helper marker sidecar — sorted u32 slice. resync analyzer 가 binary search.
    const owned_helper_ref_nodes = transformer.ownedHelperRefNodes(arena_alloc) catch &[_]u32{};
    const owned_explicit_global_ref_nodes = transformer.ownedExplicitGlobalRefNodes(arena_alloc) catch {
        self.addDiag(
            .parse_error,
            .@"error",
            module.path,
            Span.EMPTY,
            .parse,
            "Could not preserve generated global references",
            "The transformed AST's explicit global references could not be tracked safely.",
        );
        module.state = .ready;
        return;
    };
    module.transform_cache = .{
        .runtime_helpers = transformer.runtime_helpers,
        .symbol_ids = owned_symbol_ids,
        .helper_ref_nodes = owned_helper_ref_nodes,
        .explicit_global_ref_nodes = owned_explicit_global_ref_nodes,
        .destructuring_temp_bindings = transformer.destructuring_temp_bindings,
        .preserved_class_name_nodes = owned_preserved_class_names,
        .ref_deltas = prepass_ref_deltas,
    };

    // Type erasure, Flow match lowering, TypeScript enums, and supported JSX
    // lowerings preserve the edited semantic graph. JSX automatic and
    // automatic-dev add helper imports to the AST, so refresh module import/export
    // metadata from syntax without running the semantic analyzer again.
    if (can_keep_semantic_graph and !transformer.runtime_helpers.hasAny()) {
        // Generated built-ins are not source references, so the transform
        // editor cannot add them to unresolved_references. If recording them
        // runs out of memory, use the normal analyzer refresh below.
        addFlowMatchGeneratedGlobals(arena_alloc, &module.semantic.?, flow_match_generated_globals) catch {};
        const generated_globals_recorded =
            (!flow_match_generated_globals.array or module.semantic.?.unresolved_references.contains("Array")) and
            (!flow_match_generated_globals.object or module.semantic.?.unresolved_references.contains("Object"));
        if (!generated_globals_recorded) {
            resyncAfterAstMutation(self, module, arena_alloc, null) catch {
                self.addDiag(
                    .parse_error,
                    .@"error",
                    module.path,
                    Span.EMPTY,
                    .parse,
                    "Post-transform analysis refresh failed",
                    "The transformed AST could not be re-analyzed safely.",
                );
                module.state = .ready;
                return;
            };
            auditPrepassExactIfEnabled(
                arena_alloc,
                module,
                root,
                parser_node_count,
                &transformer,
                &unresolved_nodes,
                pre_transform_scope_count,
                debug_symbol_coverage,
                false,
            );
            return;
        }
        resyncModuleGraphMetadataAfterAstMutation(self, module, arena_alloc) catch {
            if (fallbackToFullSemanticResync(self, module, arena_alloc)) {
                auditPrepassExactIfEnabled(
                    arena_alloc,
                    module,
                    root,
                    parser_node_count,
                    &transformer,
                    &unresolved_nodes,
                    pre_transform_scope_count,
                    debug_symbol_coverage,
                    false,
                );
            }
            return;
        };
        auditPrepassExactIfEnabled(
            arena_alloc,
            module,
            root,
            parser_node_count,
            &transformer,
            &unresolved_nodes,
            pre_transform_scope_count,
            debug_symbol_coverage,
            true,
        );
        refreshTlaPromiseReference(module);
        module.prebuilt_stmt_info = null;
        return;
    }

    resyncAfterAstMutation(self, module, arena_alloc, null) catch {
        self.addDiag(
            .parse_error,
            .@"error",
            module.path,
            Span.EMPTY,
            .parse,
            "Post-transform analysis refresh failed",
            "The transformed AST could not be re-analyzed safely.",
        );
        module.state = .ready;
        return;
    };
    auditPrepassExactIfEnabled(
        arena_alloc,
        module,
        root,
        parser_node_count,
        &transformer,
        &unresolved_nodes,
        pre_transform_scope_count,
        debug_symbol_coverage,
        false,
    );
}

/// AST mutation 이후 module 의 graph-facing metadata 를 같은 AST 기준으로 재동기화한다.
///
/// 이 함수는 단순 semantic refresh 가 아니다. transformed/minified AST 를 기준으로
/// semantic symbol table, StmtInfo, import/require records, import/export bindings,
/// namespace access, exported_names, ESM/CJS classification, synthetic JSX imports,
/// alias table 을 다시 맞춘다.
///
/// 호출 후 invariant:
/// - `module.ast`, `module.semantic`, `module.prebuilt_stmt_info`,
///   `module.import_records`, `module.import_bindings`, `module.export_bindings`,
///   `module.exported_names`, `module.alias_table` 은 모두 같은 AST snapshot 기준이다.
/// - runtime helper virtual module 내부의 helper 이름은 unresolved global 에 남지 않는다.
///
/// 이 중앙 resync 경로를 우회해서 record/binding 만 수동 보정하면 linker, tree-shaker,
/// chunking 이 서로 다른 AST/semantic 상태를 보게 되므로 여기서만 metadata 재구축
/// 정책을 확장해야 한다 (#1913).
/// Re-analysis replaces the semantic symbol array, so old SymbolIDs cannot be
/// reused directly. Carry a rename only through a surviving declaration/facade
/// node with the same NodeIndex in both semantic snapshots. References are not
/// anchors because re-analysis can resolve one to a different binding. Names,
/// declaration spans, and synthetic-name strings are not identity. Ambiguous
/// mappings are dropped instead of guessing which new symbol inherited the old
/// identity.
fn isRenameAnchorNode(tag: NodeTag, old_symbol: SemanticSymbol, new_symbol: SemanticSymbol) bool {
    if (old_symbol.kind != new_symbol.kind) return false;
    return switch (tag) {
        .binding_identifier => true,
        .import_default_specifier, .import_namespace_specifier => old_symbol.kind == .import_binding,
        .export_default_declaration => old_symbol.decl_flags.is_default_export and new_symbol.decl_flags.is_default_export,
        else => false,
    };
}

fn remapRenamesByNodeIdentity(
    scratch_allocator: std.mem.Allocator,
    output_allocator: std.mem.Allocator,
    module_index: bundler_symbol.ModuleIndex,
    node_tags: []const NodeTag,
    old_symbol_ids: []const ?u32,
    new_symbol_ids: []const ?u32,
    old_symbols: []const SemanticSymbol,
    new_symbols: []const SemanticSymbol,
    old_renames: []const ?[]const u8,
    rebuilt: *bundler_symbol.RenameTable,
) !void {
    const old_to_new = try scratch_allocator.alloc(?u32, old_symbols.len);
    defer scratch_allocator.free(old_to_new);
    @memset(old_to_new, null);
    const old_ambiguous = try scratch_allocator.alloc(bool, old_symbols.len);
    defer scratch_allocator.free(old_ambiguous);
    @memset(old_ambiguous, false);
    const new_to_old = try scratch_allocator.alloc(?u32, new_symbols.len);
    defer scratch_allocator.free(new_to_old);
    @memset(new_to_old, null);
    const new_ambiguous = try scratch_allocator.alloc(bool, new_symbols.len);
    defer scratch_allocator.free(new_ambiguous);
    @memset(new_ambiguous, false);

    for (0..@min(@min(old_symbol_ids.len, new_symbol_ids.len), node_tags.len)) |raw| {
        const old_idx = old_symbol_ids[raw] orelse continue;
        if (old_idx >= old_symbols.len) continue;
        const new_idx = new_symbol_ids[raw] orelse continue;
        if (new_idx >= new_symbols.len) continue;
        if (!isRenameAnchorNode(node_tags[raw], old_symbols[old_idx], new_symbols[new_idx])) continue;

        if (old_to_new[old_idx]) |previous_new| {
            if (previous_new != new_idx) old_ambiguous[old_idx] = true;
        } else {
            old_to_new[old_idx] = new_idx;
        }

        if (new_to_old[new_idx]) |previous_old| {
            if (previous_old != old_idx) {
                new_ambiguous[new_idx] = true;
                old_ambiguous[previous_old] = true;
                old_ambiguous[old_idx] = true;
            }
        } else {
            new_to_old[new_idx] = old_idx;
        }
    }

    for (old_to_new, 0..) |maybe_new_idx, old_idx| {
        const new_idx = maybe_new_idx orelse continue;
        if (old_ambiguous[old_idx] or new_ambiguous[new_idx]) continue;
        if (old_idx >= old_renames.len) continue;
        const rename = old_renames[old_idx] orelse continue;
        try rebuilt.put(output_allocator, bundler_symbol.SymbolID.make(module_index, new_idx), rename);
    }
}

/// **RFC #3940 L.5a — carry-over 를 build-scope `rename_table` 기반으로 재설계**.
/// post-link tree-shake (const-materialize 등) 의 semantic resync 가 symbols 배열을 재생성하면
/// old idx 기준 rename 정보가 stale 해진다. resync 전 rename 을 읽고 같은 AST NodeIndex 의
/// old/new SymbolID 연결로 새 idx 를 찾아 `module.pending_renames` 에 stash 한다.
/// bundler 의 post-shake finalize 가 `Linker.applyPendingRenames` 로 mutable `rename_table` 에
/// 반영한다 (tree_shaker.linker 는 *const 라 put 불가 — capture=read, apply=write 분리).
/// `rename_table == null` (graph pre-pass, link 전) 이면 rename 미설정이라 no-op.
///
/// **Multi-pass 정합 (RFC #3940 L.5c review fix)**: 같은 모듈이 한 build 에서 2회 이상 resync
/// 되면 (pre-shake `applyNodeBufferCapabilityFacts` markAst + numeric post-pass markConst 등)
/// `rename_table` (link 시점 = pass0 idx) 만으로는 2차 capture 의 old_idx (= 1차 resync 후 idx)
/// 와 어긋나 stale lookup 이 된다. 그러나 **직전 resync 가 이미 old_sem(=현재) idx 기준으로
/// `pending_renames` 에 stash** 했으므로, rename source 를 `pending_renames` (직전 결과) 우선 +
/// `rename_table` (link 시점) 폴백으로 잡으면 idx-shift 와 무관하게 정합한다. 또 매 resync 마다
/// old_sem 기준으로 **새 맵을 rebuild(교체)** 해 이전 idx 의 stale entry 를 제거 — 다른 심볼이
/// 잘못된 rename 으로 오염되는 것을 막는다. 단일 resync (대부분) 는 pending 이 비어 폴백만 타므로
/// 기존과 byte-identical.
fn captureRenamesToPending(
    module: *Module,
    rename_table: *const bundler_symbol.RenameTable,
    old_sem: ModuleSemanticData,
    new_sem: *const ModuleSemanticData,
    scratch_allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
) !void {
    // old_sem 기준 새 맵을 만들어 교체 — 이전 idx 의 stale entry 누적/오염 방지 (multi-pass).
    var rebuilt: bundler_symbol.RenameTable = .{};
    // `rename_table` (link 시점 = pass0 idx) 폴백은 첫 resync 에서만 허용한다.
    // pending 이 비어도 이전 capture 가 이미 끝났을 수 있으므로 map count 대신 별도 상태를 쓴다.
    // 2차+ resync 는 old_sem idx 가 pass1+ 라 pass0 키 폴백 시 다른 심볼 rename 을 오인할 수 있다.
    const allow_table_fallback = !module.pending_rename_capture_seen;
    const ast = &(module.ast orelse return);
    const node_tags = try scratch_allocator.alloc(NodeTag, ast.nodes.items.len);
    defer scratch_allocator.free(node_tags);
    for (ast.nodes.items, 0..) |node, raw| node_tags[raw] = node.tag;
    const old_renames = try scratch_allocator.alloc(?[]const u8, old_sem.symbols.items.len);
    defer scratch_allocator.free(old_renames);
    @memset(old_renames, null);
    for (old_sem.symbols.items, 0..) |_, old_idx| {
        const old_id = bundler_symbol.SymbolID.make(module.index, old_idx);
        // 직전 resync 결과(pending) 우선; 첫 capture 만 link 시점 rename_table 폴백.
        const rename = module.pending_renames.get(old_id) orelse
            (if (allow_table_fallback) rename_table.get(old_id) else null) orelse continue;
        old_renames[old_idx] = rename;
    }
    try remapRenamesByNodeIdentity(
        scratch_allocator,
        arena,
        module.index,
        node_tags,
        old_sem.symbol_ids,
        new_sem.symbol_ids,
        old_sem.symbols.items,
        new_sem.symbols.items,
        old_renames,
        &rebuilt,
    );
    module.pending_renames = rebuilt;
    module.pending_rename_capture_seen = true;
}

/// 재분석 전 semantic 을 돌려준다 — 리네임 이관(`captureRenamesAfterResync`)은 합성 심볼이 표시된
/// **뒤에** 해야 해서(#4804) 호출자가 `refreshStableBindingRefsFromSemanticGraph` 다음에 한다.
fn refreshSemanticAndStmtInfoAfterAstMutation(
    self: anytype,
    module: *Module,
    arena_alloc: std.mem.Allocator,
) !?ModuleSemanticData {
    const ast = &(module.ast orelse return null);
    const previous_semantic = module.semantic;

    var analyzer = SemanticAnalyzer.init(arena_alloc, ast);
    {
        var semantic_scope = profile.begin(.graph_resync_semantic);
        defer semantic_scope.end();

        analyzer.is_strict_mode = true;
        analyzer.is_module = true;
        analyzer.is_ts = module.module_type.isTypeScript();
        analyzer.is_flow = self.flow or isFlowPath(module.path);
        analyzer.enable_stmt_info = true;
        // #2869 transformer pre-pass 가 표시한 runtime helper marker. analyzer 는
        // 이 marker 를 보고 helper import_specifier 와 helper call site 를 user scope
        // 가 아닌 helper_scope_map 으로 격리한다.
        if (module.transform_cache) |cache| {
            analyzer.helper_ref_nodes = cache.helper_ref_nodes;
            analyzer.explicit_global_ref_nodes = cache.explicit_global_ref_nodes;
        }
        try analyzer.analyze();

        // Restore only producer-marked binding identities. No text lookup is
        // involved, and dead intermediate nodes have no re-analyzed SymbolId.
        if (module.transform_cache) |cache| {
            for (cache.preserved_class_name_nodes) |raw| {
                if (raw >= analyzer.symbol_ids.items.len or raw >= ast.nodes.items.len or
                    ast.nodes.items[raw].tag != .binding_identifier) continue;
                const id = analyzer.symbol_ids.items[raw] orelse continue;
                if (id >= analyzer.symbols.items.len) continue;
                analyzer.symbols.items[id].decl_flags.preserve_class_name = true;
            }
        }

        module.semantic = .{
            .symbols = analyzer.symbols,
            .scopes = analyzer.scopes.items,
            .scope_maps = analyzer.scope_maps.items,
            .scope_owner_map = analyzer.scope_owner_map,
            .class_self_symbol_map = analyzer.class_self_symbol_map,
            .namespace_member_owners = analyzer.namespace_member_owners,
            .namespace_declaration_owners = analyzer.namespace_declaration_owners,
            .exported_names = analyzer.exported_names,
            .symbol_ids = analyzer.symbol_ids.items,
            .unresolved_references = analyzer.unresolved_references,
            .references = analyzer.references.items,
            .numeric_const_texts = analyzer.numeric_const_texts,
            .helper_scope_map = analyzer.helper_scope_map,
        };
        suppressRuntimeHelperInternalUnresolved(module);
        module.uses_top_level_await = analyzer.has_top_level_await;
        // base(self) 값 보존 — propagateTopLevelAwait 가 매 빌드 이 값으로 reset 후 전파.
        module.self_uses_top_level_await = analyzer.has_top_level_await;
        if (module.transform_cache) |*cache| {
            cache.symbol_ids = analyzer.symbol_ids.items;
        }
        refreshTlaPromiseReference(module);
    }

    if (self.ignore_annotations) {
        purity.clearPureCallFlags(ast);
    } else {
        purity.markUserPureCalls(ast, self.pure);
    }

    {
        var stmt_info_scope = profile.begin(.graph_resync_stmt_info);
        defer stmt_info_scope.end();

        module.prebuilt_stmt_info = null;
        if (analyzer.stmt_info_count > 0) {
            // 주의: package sideEffects 는 이 시점(parseModule 내부 prepass)
            // **이후** applySideEffectsFromPackageJson 으로 적용되므로 여기서는
            // isUserDeclaredPure() 가 거의 항상 false → 게이트 off. 실제 게이트
            // 적용은 tree_shaker 가 정확한 side-effect 상태로 재빌드할 때 일어난다.
            const gate_member_augment =
                module.memberAugmentGate(self.transform_options_base.minify_syntax);
            module.prebuilt_stmt_info = try stmt_info_mod.buildFromSemantic(
                arena_alloc,
                ast,
                analyzer.symbols.items,
                analyzer.scopes.items,
                analyzer.references.items,
                if (module.semantic) |*s| &s.unresolved_references else null,
                false,
                gate_member_augment,
            );
        }
    }
    return previous_semantic;
}

/// 링크 시점 리네임을 재분석된 심볼 번호로 옮긴다. 합성 심볼(`_default` 등)은
/// `populateSyntheticSymbols` 가 표시한 뒤에야 짝을 찾을 수 있으므로 반드시
/// `refreshStableBindingRefsFromSemanticGraph` **다음**에 부른다 — 먼저 부르면 짝을 못 찾아 리네임이
/// 버려지고 모듈 간 같은 이름(`var _default`)이 겹친다 (#4804, axios es5 + minify-syntax).
fn captureRenamesAfterResync(
    self: anytype,
    module: *Module,
    arena_alloc: std.mem.Allocator,
    rename_table: ?*const bundler_symbol.RenameTable,
    previous_semantic: ?ModuleSemanticData,
) !void {
    if (self.minify_identifiers) return;
    const rt = rename_table orelse return;
    const old_sem = previous_semantic orelse return;
    const new_sem = if (module.semantic) |*sem| sem else return;
    try captureRenamesToPending(module, rt, old_sem, new_sem, self.allocator, arena_alloc);
}

fn refreshStableBindingRefsFromSemanticGraph(
    self: anytype,
    module: *Module,
    arena_alloc: std.mem.Allocator,
    cat: profile.Category,
) !void {
    var binding_refs_scope = profile.begin(cat);
    defer binding_refs_scope.end();

    const sem = if (module.semantic) |*s| s else return;
    const scope0: ?std.StringHashMapUnmanaged(usize) =
        if (sem.scope_maps.len > 0) sem.scope_maps[0] else null;
    for (module.import_bindings) |*ib| {
        ib.local_symbol = bundler_symbol.SymbolRef.invalid;
        // #3068: helper binding 은 user 가 같은 이름 점유 시에도 격리된 helper_scope_map
        // 에서 lookup — 일반 module_scope.get 면 user sym 을 잘못 가리킨다 (linker
        // populateImportSymbols 와 동일 정책).
        const sym_lookup: ?usize = if (ib.is_helper)
            sem.helper_scope_map.get(ib.local_name)
        else if (scope0) |module_scope| module_scope.get(ib.local_name) else null;
        if (sym_lookup) |sym_idx| {
            ib.local_symbol = bundler_symbol.SymbolRef.makeSemantic(module.index, sym_idx);
        }
    }

    if (module.alias_table) |*table| table.deinit();
    module.alias_table = AliasTable.init(self.allocator);
    try binding_scanner_mod.populateSyntheticSymbols(
        &module.alias_table.?,
        module.index,
        module.export_bindings,
        &sem.symbols,
        arena_alloc,
        scope0,
    );
}

/// Numeric const materialization replaces identifier reads and may let minify fold
/// expressions, but it does not add/remove import or export declarations. Keep the
/// expensive syntax-level scanners intact for general transforms and use this path
/// only when the caller owns that invariant.
pub fn resyncAfterConstMaterialization(
    self: anytype,
    module: *Module,
    arena_alloc: std.mem.Allocator,
    rename_table: ?*const bundler_symbol.RenameTable,
) !void {
    var resync_scope = profile.begin(.graph_resync);
    defer resync_scope.end();
    var const_scope = profile.begin(.graph_resync_const);
    defer const_scope.end();

    _ = &(module.ast orelse return);
    const previous_semantic = try refreshSemanticAndStmtInfoAfterAstMutation(self, module, arena_alloc);
    try refreshStableBindingRefsFromSemanticGraph(self, module, arena_alloc, .graph_resync_binding_refs);
    try captureRenamesAfterResync(self, module, arena_alloc, rename_table, previous_semantic);
}

/// Rebuild graph-facing module metadata from the transformed AST without
/// re-running semantic analysis. This is used when the transformer has already
/// edited the retained SymbolId/ScopeId graph and only syntax-level import or
/// export records changed.
pub fn resyncModuleGraphMetadataAfterAstMutation(
    self: anytype,
    module: *Module,
    arena_alloc: std.mem.Allocator,
) !void {
    const ast = &(module.ast orelse return);
    const previous_import_records = module.import_records;

    var scan_result: import_scanner.ScanResult = undefined;
    {
        var import_scan_scope = profile.begin(.graph_resync_import_scan);
        defer import_scan_scope.end();

        scan_result = try import_scanner.extractImportsWithCjsDetectionAndDefines(arena_alloc, ast, self.defines);
        module.import_records = try mergeImportRecords(arena_alloc, previous_import_records, scan_result.records);
        // specifier dupe — arena 로 owned 화 (#raw-require UAF 회피).
        for (module.import_records) |*r| {
            if (arena_alloc.dupe(u8, r.specifier)) |owned| r.specifier = owned else |_| {}
        }
        try import_scanner.markPostScanFlags(arena_alloc, ast, module.import_records);
    }

    {
        var import_bindings_scope = profile.begin(.graph_resync_import_bindings);
        defer import_bindings_scope.end();

        // #3067 이후 transformer 가 직접 추가하던 synthetic ImportBinding (JSX runtime
        // 등) 이 정식 import 노드로 대체됐다 — post-transform AST 에서 일반 binding 으로
        // 추출되므로 previous 에서 따로 보존할 synthetic binding 이 없다.
        const helper_refs: ?[]const u32 = if (module.transform_cache) |cache| cache.helper_ref_nodes else null;

        // counter$4 진짜 근본 fix: 1차 (parse 단계 parser_metadata.zig) 의
        // collectNamespaceAccesses 결과를 local→props 맵으로 백업. transformer 가
        // `metric.counter(...)` 같은 namespace access 를 inline / helper substitution 으로
        // 변형하면 2차 collectNamespaceAccesses (post-transform AST 기반) 가 못 잡아
        // `namespace_used_properties=&.{}` (length=0) 로 reset → tree-shake 가 그 module 의
        // export reachable seed 안 함 → namespace getter dangling (effect-ts 의
        // `counter$4 is not defined`). 1차 가 잡은 props 를 2차 결과와 union 으로 keep.
        var prev_props_map = std.StringHashMapUnmanaged([]const []const u8){};
        defer prev_props_map.deinit(arena_alloc);
        for (module.import_bindings) |ib_prev| {
            if (ib_prev.kind != .namespace) continue;
            if (ib_prev.namespace_used_properties) |props| {
                if (props.len > 0) {
                    prev_props_map.put(arena_alloc, ib_prev.local_name, props) catch continue;
                }
            }
        }

        module.import_bindings = try binding_scanner_mod.extractImportBindings(arena_alloc, ast, module.import_records, helper_refs);

        // PR #3738 (C6 perf): namespace 외 모든 import local 도 interest 에 추가 — linker 의
        // .named / cjs default / esm wrapper default 분석에 share. transform_prepass 시점에는
        // resolve 미완료라 정확한 4 kind 판별 불가, 보수적으로 모든 import local 색인.
        // 일반 모듈은 import binding 수가 작아 (수개~수십개) 색인 size 영향 무시 가능.
        var extra_locals: std.ArrayListUnmanaged([]const u8) = .empty;
        defer extra_locals.deinit(arena_alloc);
        for (module.import_bindings) |ib_extra| {
            if (ib_extra.kind == .namespace) continue;
            if (ib_extra.local_name.len > 0) try extra_locals.append(arena_alloc, ib_extra.local_name);
        }
        // index 를 module 에 store — linker 가 fetch (모듈당 build 1회 절약).
        const ns_idx = try binding_scanner_mod.collectNamespaceAccessesAndBuildIndex(
            arena_alloc,
            ast,
            module.import_bindings,
            extra_locals.items,
            .{ .reachable_only = false }, // linker 호환 (orphan node 포함)
        );
        // 옛 index 는 parse_arena 소유 — 별도 deinit 불필요 (arena 통째 free). null 으로만 덮어씀.
        module.namespace_access_index = ns_idx;

        // 1차 결과와 union: 2차 가 못 잡은 access 도 keep.
        for (module.import_bindings) |*ib_new| {
            if (ib_new.kind != .namespace) continue;
            const new_props = ib_new.namespace_used_properties orelse continue;
            const prev_props = prev_props_map.get(ib_new.local_name) orelse continue;
            if (new_props.len == 0) {
                ib_new.namespace_used_properties = prev_props;
                continue;
            }
            // 둘 다 non-empty — union.
            var seen = std.StringHashMapUnmanaged(void){};
            defer seen.deinit(arena_alloc);
            for (new_props) |p| seen.put(arena_alloc, p, {}) catch {};
            var added: usize = 0;
            for (prev_props) |p| {
                if (!seen.contains(p)) added += 1;
            }
            if (added == 0) continue;
            const merged = arena_alloc.alloc([]const u8, new_props.len + added) catch continue;
            @memcpy(merged[0..new_props.len], new_props);
            var mi: usize = new_props.len;
            for (prev_props) |p| {
                if (!seen.contains(p)) {
                    merged[mi] = p;
                    mi += 1;
                }
            }
            ib_new.namespace_used_properties = merged;
        }
    }

    {
        var export_bindings_scope = profile.begin(.graph_resync_export_bindings);
        defer export_bindings_scope.end();

        module.export_bindings = try binding_scanner_mod.extractExportBindings(
            arena_alloc,
            ast,
            module.import_records,
            module.import_bindings,
        );
        module.exported_names = projectExportedNames(arena_alloc, module.export_bindings);
        @import("requested_exports.zig").computeBarrelFlags(module);
        @import("requested_exports.zig").populateExportIndexByName(module, self.allocator) catch {};
    }

    const has_refreshed_cjs = scan_result.has_cjs_require or
        scan_result.has_module_exports or
        scan_result.has_exports_dot;
    const has_refreshed_esm = if (module.exports_kind == .commonjs and has_refreshed_cjs)
        false
    else
        scan_result.has_esm_syntax;

    const refreshed_scan_result = import_scanner.ScanResult{
        .records = module.import_records,
        .has_esm_syntax = has_refreshed_esm,
        .has_cjs_require = scan_result.has_cjs_require,
        .has_module_exports = scan_result.has_module_exports,
        .has_exports_dot = scan_result.has_exports_dot,
        .has_esmodule_marker = scan_result.has_esmodule_marker,
    };

    {
        var classify_scope = profile.begin(.graph_resync_classify);
        defer classify_scope.end();

        // #3062: transformer 가 JSX runtime import 를 정식 AST 노드로 추가 → resync 의
        // import_scanner / binding_scanner 가 일반 import 로 detect. synthetic
        // ImportRecord/Binding inject 우회 경로 제거.

        // 기존 exports_kind 가 ESM 인데 post-transform scan 이 `.none` 으로 떨어지는 경우
        // (예: TS interface-only 파일의 `export {};` 를 transformer 가 drop) ESM 분류를 유지한다.
        // `.none` 으로 강등하면 Pass 2 markEsmCjsHybrid 가 node_modules + def_format unknown
        // 모듈을 implicit CJS 로 승격시켜, `export *` chain 의 빈 source 가 CJS wrapper 로
        // wrap 되고 `resolveOrCjsFallback` 이 잘못된 모듈을 named import 의 source 로 반환한다
        // (kysely/cheerio 회귀 #2052/#2051).
        const refreshed_kind = determineExportsKind(refreshed_scan_result, module.path);
        const previous_kind = module.exports_kind;
        const preserve_esm = refreshed_kind == .none and previous_kind.isEsm();
        module.exports_kind = if (preserve_esm) previous_kind else refreshed_kind;
        // #4520: wrap_kind 는 `promoteExportsKinds` 가 그래프 전역 정보로 정하는 결정이라
        // 여기(단일 모듈 구문 재스캔)서 복원할 수 없다. 확정 전(파스 직후 prepass / 디스크
        // 캐시 복원)에는 이 재계산이 곧 최초 분류라 유지하고, 확정 후(tree-shaker 의 post-link
        // AST 변형 resync)에는 건드리지 않는다.
        //
        // 이 가드가 없으면 크로스-모듈 const-inline 등으로 AST 가 변형된 dynamic import
        // target 의 `__esm` lazy wrap 이 `.none` 으로 풀려, emitter 가 `import("./x")` 를
        // `init_x()` 호출로 재작성하지 못하고 원문 그대로 남긴다 (번들 밖 sibling 파일을
        // 찾아 런타임 실패) + 모듈 본문이 top-level 로 평탄화되어 TDZ 까지 유발한다.
        if (!self.wrap_kinds_finalized) {
            module.wrap_kind = if (module.exports_kind == .commonjs) .cjs else .none;
        }
        module.has_cjs_export_signal = refreshed_scan_result.has_module_exports or refreshed_scan_result.has_exports_dot;
        module.has_esmodule_marker = refreshed_scan_result.has_esmodule_marker;
        module.can_skip_cjs_default_interop = Module.computeCanSkipCjsDefaultInterop(
            module.wrap_kind == .cjs,
            refreshed_scan_result.has_module_exports,
            refreshed_scan_result.has_exports_dot,
            refreshed_scan_result.has_esmodule_marker,
        );
    }

    try refreshStableBindingRefsFromSemanticGraph(self, module, arena_alloc, .graph_resync_alias);
}

pub fn resyncAfterAstMutation(
    self: anytype,
    module: *Module,
    arena_alloc: std.mem.Allocator,
    rename_table: ?*const bundler_symbol.RenameTable,
) !void {
    var resync_scope = profile.begin(.graph_resync);
    defer resync_scope.end();

    const previous_semantic = try refreshSemanticAndStmtInfoAfterAstMutation(self, module, arena_alloc);
    try resyncModuleGraphMetadataAfterAstMutation(self, module, arena_alloc);
    try captureRenamesAfterResync(self, module, arena_alloc, rename_table, previous_semantic);
}

/// #4438 디스크 캐시 load 경로 전용 — parser 없이 복원된 `module.ast`(+semantic)만으로
/// `materialize`(parser_metadata.zig)의 graph 레벨 출력을 재구성한다. `materialize` 는
/// `parser.scan_*`(parse 중 수집)에 의존하지만, `resyncAfterAstMutation` 이 같은 데이터를
/// AST 재순회로 재생성한다(import_records / import·export_bindings / exported_names /
/// namespace_access_index / exports_kind / wrap_kind / cjs 플래그 / semantic·prebuilt_stmt_info /
/// alias_table). load 는 AST(+semantic)만 복원하므로 이 헬퍼로 메타를 채운 뒤 transformer
/// pre-pass(`run`)를 재실행하면 cold parse 경로와 동일한 module 상태에 도달한다.
///
/// `materialize` 에만 있고 `resync` 에 없는 갭을 보완:
///  - **flow-enum 런타임 import**: 게이트 `has_flow_enum_declaration` 는 Ast 필드라 복원된다.
///    (resync 는 transformer 가 enum 을 이미 lower 한 post-transform AST 에서 돌기 때문에 이
///    inject 를 skip 하지만, load 는 pre-transform AST 를 복원하므로 materialize 처럼 재현해야 함.)
///
/// 알려진 미보완 갭(PR② ON==OFF 코퍼스에서 검증/보완): import/export 문이 전혀 없고
/// `import.meta` 만 있는 .js 모듈은 materialize 가 `parser.has_module_syntax` 로 `.esm` 분류하나
/// resync 의 scan(import/export 노드 기반)은 `.none` 으로 떨어질 수 있다. 그런 단독 모듈은 극히
/// 드물고 대부분 import/export 를 동반하므로 PR① 범위에서 제외한다.
///
/// 출력 영향 0: 호출자는 graph 통합 PR②(load hit 배선) — 현재 미연결(동등성 테스트 전용).
/// `self` 는 graph(`self.defines` / `self.allocator` 사용), `arena_alloc` 는 모듈 parse_arena.
pub fn materializeFromCachedAst(self: anytype, module: *Module, arena_alloc: std.mem.Allocator) !void {
    try resyncAfterAstMutation(self, module, arena_alloc, null);
    const ast = &(module.ast orelse return);
    if (ast.has_flow_enum_declaration) {
        module.import_records = injectFlowEnumRuntimeImport(arena_alloc, module.import_records) catch module.import_records;
    }
}

test "rename carry-over follows same-node SymbolID lineage and drops ambiguity" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();
    const module_index: bundler_symbol.ModuleIndex = @enumFromInt(0);
    const node_tags = [_]NodeTag{
        .binding_identifier,
        .identifier_reference,
        .export_default_declaration,
        .binding_identifier,
        .binding_identifier,
    };
    const old_ids = [_]?u32{ 1, 1, 2, 3, 3 };
    const new_ids = [_]?u32{ 4, 6, 5, 7, 8 };
    const old_symbols = [_]SemanticSymbol{
        testRenameSymbol(.variable_let, false),
        testRenameSymbol(.variable_let, false),
        testRenameSymbol(.variable_const, true),
        testRenameSymbol(.variable_let, false),
    };
    const new_symbols = [_]SemanticSymbol{
        testRenameSymbol(.variable_let, false),
        testRenameSymbol(.variable_let, false),
        testRenameSymbol(.variable_const, true),
        testRenameSymbol(.variable_let, false),
        testRenameSymbol(.variable_let, false),
        testRenameSymbol(.variable_const, true),
        testRenameSymbol(.variable_let, false),
        testRenameSymbol(.variable_let, false),
        testRenameSymbol(.variable_let, false),
    };
    const old_renames = [_]?[]const u8{ null, "renamed-a", "renamed-b", "ambiguous" };
    var rebuilt: bundler_symbol.RenameTable = .{};

    try remapRenamesByNodeIdentity(
        allocator,
        allocator,
        module_index,
        &node_tags,
        &old_ids,
        &new_ids,
        &old_symbols,
        &new_symbols,
        &old_renames,
        &rebuilt,
    );

    try std.testing.expectEqual(@as(u32, 2), rebuilt.count());
    try std.testing.expectEqualStrings("renamed-a", rebuilt.get(bundler_symbol.SymbolID.make(module_index, 4)).?);
    try std.testing.expectEqualStrings("renamed-b", rebuilt.get(bundler_symbol.SymbolID.make(module_index, 5)).?);
    try std.testing.expect(rebuilt.get(bundler_symbol.SymbolID.make(module_index, 6)) == null);
    try std.testing.expect(rebuilt.get(bundler_symbol.SymbolID.make(module_index, 7)) == null);
    try std.testing.expect(rebuilt.get(bundler_symbol.SymbolID.make(module_index, 8)) == null);
}

test "rename carry-over drops many-to-one node lineage" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();
    const module_index: bundler_symbol.ModuleIndex = @enumFromInt(0);
    const node_tags = [_]NodeTag{ .binding_identifier, .binding_identifier };
    const old_ids = [_]?u32{ 1, 2 };
    const new_ids = [_]?u32{ 4, 4 };
    const old_symbols = [_]SemanticSymbol{
        testRenameSymbol(.variable_let, false),
        testRenameSymbol(.variable_let, false),
        testRenameSymbol(.variable_let, false),
    };
    const new_symbols = [_]SemanticSymbol{
        testRenameSymbol(.variable_let, false),
        testRenameSymbol(.variable_let, false),
        testRenameSymbol(.variable_let, false),
        testRenameSymbol(.variable_let, false),
        testRenameSymbol(.variable_let, false),
    };
    const old_renames = [_]?[]const u8{ null, "renamed-a", null };
    var rebuilt: bundler_symbol.RenameTable = .{};

    try remapRenamesByNodeIdentity(
        allocator,
        allocator,
        module_index,
        &node_tags,
        &old_ids,
        &new_ids,
        &old_symbols,
        &new_symbols,
        &old_renames,
        &rebuilt,
    );

    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());
}

fn testRenameSymbol(kind: SemanticSymbolKind, is_default_export: bool) SemanticSymbol {
    return .{
        .name = Span.EMPTY,
        .scope_id = .none,
        .kind = kind,
        .decl_flags = .{ .is_default_export = is_default_export },
        .declaration_span = Span.EMPTY,
    };
}
