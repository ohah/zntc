//! ModuleGraph transformer pre-pass and post-transform metadata resync helpers.

const std = @import("std");
const Module = @import("../module.zig").Module;
const ModuleSemanticData = @import("../module.zig").ModuleSemanticData;
const CjsRuntimeInternalSymbolIds = @import("../module.zig").CjsRuntimeInternalSymbolIds;
const EsmRuntimeInternalSymbolIds = @import("../module.zig").EsmRuntimeInternalSymbolIds;
const EsmInteropRuntimeHelperSymbolIds = @import("../module.zig").EsmInteropRuntimeHelperSymbolIds;
const WorkletFactoryLocalBinding = @import("../module.zig").WorkletFactoryLocalBinding;
const PostGraphOutputBinding = @import("../module.zig").PostGraphOutputBinding;
const RuntimeHelperImportOutputBinding = @import("../module.zig").RuntimeHelperImportOutputBinding;
const AliasTable = @import("../module.zig").AliasTable;
const binding_scanner_mod = @import("../binding_scanner.zig");
const bundler_symbol = @import("../symbol.zig");
const runtime_helper_names = @import("../../runtime_helper_names.zig");
const import_scanner = @import("../import_scanner.zig");
const stmt_info_mod = @import("../stmt_info.zig");
const cjs_patterns = @import("../tree_shaker/cjs_patterns.zig");
const purity = @import("../purity.zig");
const profile = @import("../../profile.zig");
const ast_mod = @import("../../parser/ast.zig");
const ast_walk = @import("../../parser/ast_walk.zig");
const reference_walk = @import("../../semantic/reference_walk.zig");
const module_parser = @import("../../parser/module.zig");
const token_mod = @import("../../lexer/token.zig");
const Scanner = @import("../../lexer/scanner.zig").Scanner;
const NodeTag = ast_mod.Node.Tag;
const SemanticSymbol = @import("../../semantic/symbol.zig").Symbol;
const SemanticSymbolId = @import("../../semantic/symbol.zig").SymbolId;
const SemanticSymbolKind = @import("../../semantic/symbol.zig").SymbolKind;
const SemanticReference = @import("../../semantic/symbol.zig").Reference;
const SemanticSyntheticKind = @import("../../semantic/symbol.zig").SyntheticKind;
const ScopeId = @import("../../semantic/scope.zig").ScopeId;
const SemanticScope = @import("../../semantic/scope.zig").Scope;
const SemanticAnalyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
const isTypeOnlyNode = @import("../../transformer/transformer/type_only.zig").isTypeOnlyNode;
const define_mod = @import("../../transformer/transformer/define.zig");
const drop_mod = @import("../../transformer/transformer/drop.zig");
const worklet_mod = @import("../../transformer/transformer/worklet.zig");
const styled_components_scan = @import("../../transformer/transformer/styled_components.zig");
const emotion_scan = @import("../../transformer/transformer/emotion.zig");
const refresh_mod = @import("../../transformer/transformer/refresh.zig");
const worklet_plugin = @import("../../transformer/plugins/worklet_plugin.zig");
const plugin_mod = @import("../plugin.zig");
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
    const stmt_raw = @backingInt(stmt_idx);
    if (stmt_idx.isNone() or stmt_raw >= ast.nodes.items.len) return null;
    const stmt = ast.nodes.items[stmt_raw];
    if (stmt.tag != .variable_declaration) return null;

    const extra = stmt.data.extra;
    if (extra + 2 >= ast.extra_data.items.len) return null;
    const list_start = ast.extra_data.items[extra + 1];
    const list_len = ast.extra_data.items[extra + 2];
    if (list_len != 1 or list_start >= ast.extra_data.items.len) return null;

    const decl_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[list_start]));
    if (decl_idx.isNone() or @backingInt(decl_idx) >= ast.nodes.items.len) return null;
    const decl = ast.nodes.items[@backingInt(decl_idx)];
    if (decl.tag != .variable_declarator or decl.data.extra >= ast.extra_data.items.len) return null;
    const binding_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[decl.data.extra]));
    if (binding_idx.isNone() or @backingInt(binding_idx) >= ast.nodes.items.len) return null;
    if (ast.nodes.items[@backingInt(binding_idx)].tag != .binding_identifier) return null;

    const binding_raw = @backingInt(binding_idx);
    if (binding_raw >= semantic.symbol_ids.len) return null;
    const symbol_raw = semantic.symbol_ids[binding_raw] orelse return null;
    if (symbol_raw >= semantic.symbols.items.len) return null;
    const symbol = semantic.symbols.items[symbol_raw];
    if (symbol.scope_id.isNone()) return null;

    return .{
        .binding_node_index = binding_raw,
        .symbol_id = @fromBackingInt(@intCast(symbol_raw)),
        .scope_id = symbol.scope_id,
    };
}

fn refreshTlaPromiseReference(module: *Module) void {
    module.tla_promise_reference = null;
    const stmt_raw = module.tla_iife_stmt orelse return;
    const ast = &(module.ast orelse return);
    const semantic = &(module.semantic orelse return);
    module.tla_promise_reference = tlaPromiseReference(ast, semantic, @fromBackingInt(@intCast(stmt_raw)));
}

/// 보수적 graph pre-pass 게이트.
///
/// graph 단계 pre-pass 는 helper import·graph-visible 전역 또는 최종 이름 결정에 쓸
/// 합성 SymbolId 를 만드는 모듈에 필요하다. 단순 ESM/TS-strip 모듈은 parser metadata와
/// emit 단계의 legacy transformer/codegen 경로를 그대로 쓴다.
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

        // AST plugins run while transforming the module. Their generated
        // bindings and references must enter the graph before linker tree
        // shaking, even when no built-in syntax transform is otherwise needed.
        if (hasAstTransformPlugin(self.plugins, &module.ast.?)) return true;

        // Check cheap single-byte flags before the heavier option predicate.
        if (self.minify_identifiers) return true;
        // react_refresh / styled-components / emotion 은 emitter·`run` 과 마찬가지로 user
        // code 에만 적용된다 (`/node_modules/` 밖). node_modules 의 plain ESM/ES5 dep 까지
        // pre-pass 를 돌리던 게 가장 큰 낭비였다 — 그 모듈들은 helper import 도 안 만든다.
        const is_user_code = std.mem.indexOf(u8, module.path, "/node_modules/") == null;
        if (is_user_code and self.react_refresh and refresh_mod.computeRefreshEnabled(.{
            .react_refresh = true,
            .jsx_filename = module.path,
        })) return true;
        if (is_user_code and (self.styled_components or self.emotion)) {
            // These transforms can only recognize bindings from their configured
            // package imports. JSX is gated below independently for css-prop paths.
            if (module.ast == null) return true;
            if (hasConfiguredStylePluginImport(self, &module.ast.?)) return true;
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

    // The built-in worklet plugin changes only modules containing a supported
    // directive, auto-worklet call, marker, or enabled web-platform check.
    // Keep a conservative AST signal scan so ordinary RN dependencies avoid
    // the graph pre-pass while every transform-capable module stays on it.
    if (self.worklet_transform) {
        const is_rn_core = std.mem.indexOf(u8, module.path, "/node_modules/react-native/") != null or
            std.mem.indexOf(u8, module.path, "/node_modules/@react-native/") != null;
        if (!is_rn_core and hasWorkletTransformSignal(ast, self.transform_options_base.substitute_web_platform_checks)) {
            return true;
        }
    }

    {
        var options_scope = profile.begin(.graph_discover_pm_prepass_decision_options);
        defer options_scope.end();
        return self.transform_options_base.requiresGraphPrePass(ast);
    }
}

fn hasAstTransformPlugin(plugins: []const plugin_mod.Plugin, ast: *const ast_mod.Ast) bool {
    var has_function = false;
    var has_object = false;
    var has_call = false;
    var has_class = false;
    for (ast.nodes.items) |node| {
        switch (node.tag) {
            .function, .function_declaration, .function_expression, .arrow_function_expression, .method_definition => has_function = true,
            .object_expression => has_object = true,
            .call_expression => has_call = true,
            .class_declaration, .class_expression => has_class = true,
            else => {},
        }
    }

    for (plugins) |plugin| {
        if ((plugin.onFunction != null and has_function) or
            (plugin.autoWorkletCallees.len > 0 and has_call)) return true;
        if (plugin.visitor) |visitor| {
            if (visitor.on_program != null or
                (visitor.on_object_expression != null and has_object) or
                (visitor.on_call_expression != null and has_call) or
                ((visitor.on_class_declaration != null or visitor.on_class_expression != null) and has_class)) return true;
        }
    }
    return false;
}

/// Scan imports once when one or both CSS plugins are configured. Their exact
/// source matchers are shared with the transformer so aliases and custom paths
/// keep the same behavior in the pre-pass gate.
fn hasConfiguredStylePluginImport(self: anytype, ast: *const ast_mod.Ast) bool {
    const statements = ast_walk.topLevelStatementIndices(ast) orelse return true;
    for (statements) |raw_stmt| {
        if (raw_stmt >= ast.nodes.items.len) return true;
        const node = ast.nodes.items[raw_stmt];
        if (node.tag != .import_declaration) continue;
        const extra = node.data.extra;
        if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 6) return true;
        const x = module_parser.readImportDeclExtras(ast, extra);
        if (module_parser.isDeclarationTypeOnly(x) or x.source.isNone()) continue;
        if (@backingInt(x.source) >= ast.nodes.items.len) return true;
        const source_node = ast.getNode(x.source);
        if (source_node.tag != .string_literal) continue;
        const source = import_scanner.stripQuotes(ast.getText(source_node.span)) orelse continue;
        if (self.styled_components and styled_components_scan.isStyledImportSourceWithExtras(
            source,
            self.styled_components_top_level_import_paths,
        )) return true;
        if (self.emotion and
            (emotion_scan.isEmotionCssSourceWithExtraSources(source, self.emotion_extra_css_sources) or
                emotion_scan.isEmotionStyledSourceWithExtraSources(source, self.emotion_extra_styled_sources))) return true;
    }
    return false;
}

/// Type erasure, Flow match/enum/component lowering, and local TS import-equals
/// aliases preserve the module graph. For the restricted no-plugin/no-helper
/// case, the transform editor already carries exact binding/reference/scope
/// edges; Flow enum runtime imports are materialized before this pre-pass.
/// Keep the predicate deliberately narrow: non-static external import-equals,
/// other runtime Flow extensions, import rewriting, JSX, runtime helpers, and
/// semantic-changing transforms continue through the full resync path.
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
                    const child = ast.getNode(@fromBackingInt(@intCast(child_raw)));
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

fn hasExplicitGlobalReferenceNamed(
    ast: *const ast_mod.Ast,
    explicit_global_reference_nodes: *const std.AutoHashMapUnmanaged(u32, void),
    name: []const u8,
) bool {
    var nodes = explicit_global_reference_nodes.keyIterator();
    while (nodes.next()) |raw| {
        if (raw.* >= ast.nodes.items.len) continue;
        const node = ast.nodes.items[raw.*];
        if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;
        if (std.mem.eql(u8, ast.getText(node.span), name)) return true;
    }
    return false;
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

/// Local TypeScript import-equals aliases preserve module graph shape when
/// lowered to const bindings.
fn isSupportedLocalImportEquals(ast: *const ast_mod.Ast, node: ast_mod.Node) bool {
    if (node.tag != .ts_import_equals_declaration) return false;
    var value_idx = node.data.binary.right;
    while (!value_idx.isNone()) {
        if (@backingInt(value_idx) >= ast.nodes.items.len) return false;
        const value = ast.getNode(value_idx);
        switch (value.tag) {
            .identifier_reference => return true,
            .static_member_expression => {
                if (value.data.extra >= ast.extra_data.items.len) return false;
                value_idx = @fromBackingInt(@intCast(ast.extra_data.items[value.data.extra]));
            },
            else => return false,
        }
    }
    return false;
}

/// A static external import-equals keeps the same `require("specifier")` call
/// through lowering. Parser scan and transformed-AST scan therefore retain the
/// same loader record and CJS signal.
fn isSupportedExternalRequireImportEquals(ast: *const ast_mod.Ast, node: ast_mod.Node) bool {
    if (node.tag != .ts_import_equals_declaration) return false;
    const value_idx = node.data.binary.right;
    if (value_idx.isNone() or @backingInt(value_idx) >= ast.nodes.items.len) return false;
    const value = ast.getNode(value_idx);
    if (value.tag != .call_expression) return false;
    if (!ast.hasExtra(value.data.extra, 2)) return false;

    const callee_idx = ast.readExtraNode(value.data.extra, 0);
    if (callee_idx.isNone() or @backingInt(callee_idx) >= ast.nodes.items.len) return false;
    const callee = ast.getNode(callee_idx);
    const callee_name = ast.getText(callee.span);
    const arg_count = ast.readExtra(value.data.extra, 2);
    if (callee.tag != .identifier_reference or !std.mem.eql(u8, callee_name, "require")) return false;
    if (arg_count != 1) return false;

    const args_start = ast.readExtra(value.data.extra, 1);
    if (args_start >= ast.extra_data.items.len) return false;
    const arg_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[args_start]));
    return !arg_idx.isNone() and @backingInt(arg_idx) < ast.nodes.items.len and
        ast.getNode(arg_idx).tag == .string_literal;
}

/// Plain top-level `export * from "specifier"` keeps the same re-export
/// loader record through lowering. Namespace re-exports and import attributes
/// stay on the full graph-resync path.
fn isSupportedPlainExportAll(
    ast: *const ast_mod.Ast,
    node_idx: ast_mod.NodeIndex,
    top_level_statements: *const std.DynamicBitSet,
) bool {
    if (node_idx.isNone() or @backingInt(node_idx) >= ast.nodes.items.len) return false;
    const node = ast.getNode(node_idx);
    if (node.tag != .export_all_declaration) return false;
    if (!top_level_statements.isSet(@backingInt(node_idx))) return false;

    const export_all = module_parser.readExportAllExtras(ast, node.data.extra);
    if (!export_all.exported_name.isNone() or export_all.attrs_len != 0) return false;
    if (export_all.source.isNone() or @backingInt(export_all.source) >= ast.nodes.items.len) return false;
    return ast.getNode(export_all.source).tag == .string_literal;
}

/// Keeping the semantic graph is safe only when the transform leaves each
/// runtime import's module-graph shape unchanged. Ordinary unused named
/// imports can be elided, and inline type-only specifiers can be removed, so
/// runtime imports require verbatim syntax except for the plain-JavaScript
/// console-drop subset proved below.
fn hasStableRuntimeImports(
    ast: *const ast_mod.Ast,
    options: TransformOptions,
    allow_nonverbatim_javascript_imports: bool,
) bool {
    const statements = ast_walk.topLevelStatementIndices(ast) orelse return false;
    for (statements) |raw_stmt| {
        if (raw_stmt >= ast.nodes.items.len) return false;
        const node = ast.nodes.items[raw_stmt];
        if (node.tag != .import_declaration) continue;
        const extra = node.data.extra;
        if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 6) return false;
        const import = module_parser.readImportDeclExtras(ast, extra);
        if (import.is_type_only) continue;
        if (import.phase != .none or import.attrs_len != 0) return false;
        if (import.specs_len == 0) continue;
        if (!options.verbatim_module_syntax and !allow_nonverbatim_javascript_imports) return false;
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

/// Plain JavaScript imports are not elided by type-only import handling. A
/// console-drop edit can therefore refresh their module records from the
/// transformed AST and keep the same semantic graph, provided this is the only
/// graph-changing transform in the module. Other modes keep the stricter
/// verbatim-module-syntax gate.
fn canRetainPlainJavaScriptImportsForConsoleDrop(
    self: anytype,
    module: *const Module,
    ast: *const ast_mod.Ast,
    options: TransformOptions,
    retained_simple_console_drops: bool,
) bool {
    if (!retained_simple_console_drops or module.module_type != .js or
        self.flow or self.worklet_transform or self.plugins.len != 0 or
        isFlowPath(module.path) or ast.has_jsx or ast.has_decorator or
        module.uses_top_level_await or module.self_uses_top_level_await)
    {
        return false;
    }
    return !options.unsupported.hasAny() and !options.drop_debugger and
        options.drop_labels.len == 0 and options.define.len == 0 and
        !options.minify_syntax and !options.minify_whitespace and
        !options.experimental_decorators and !options.emit_decorator_metadata and
        !options.react_refresh and !options.styled_components and !options.emotion and
        !options.jsx_transform and options.plugins.len == 0;
}

/// A configured label only changes the AST when a labeled statement has that
/// exact source spelling. Missing labels are treated as a potential edit so a
/// malformed AST fails closed to semantic reanalysis.
fn hasDroppedLabeledStatement(ast: *const ast_mod.Ast, labels: []const []const u8) bool {
    if (labels.len == 0) return false;
    for (ast.nodes.items) |node| {
        if (node.tag != .labeled_statement) continue;
        const label_idx = node.data.binary.left;
        if (label_idx.isNone() or @backingInt(label_idx) >= ast.nodes.items.len) return true;
        const label_name = ast.getText(ast.getNode(label_idx).span);
        for (labels) |dropped| {
            if (std.mem.eql(u8, label_name, dropped)) return true;
        }
    }
    return false;
}

fn hasDroppedConsoleStatement(ast: *const ast_mod.Ast) bool {
    for (ast.nodes.items) |node| {
        if (node.tag == .expression_statement and drop_mod.isConsoleCallInAst(ast, node)) return true;
    }
    return false;
}

/// Static named re-exports preserve the same loader record if every exported
/// name is an identifier and the declaration has no attributes. Inline
/// type-only specifiers are allowed because their re-export still evaluates
/// the source module for side effects after TypeScript erasure.
fn isSupportedStaticNamedReExport(ast: *const ast_mod.Ast, export_decl: module_parser.ExportNamedExtras) bool {
    if (!export_decl.decl.isNone() or export_decl.source.isNone() or export_decl.attrs_len != 0) return false;
    if (@backingInt(export_decl.source) >= ast.nodes.items.len or
        ast.getNode(export_decl.source).tag != .string_literal) return false;
    if (export_decl.specs_start > ast.extra_data.items.len or
        export_decl.specs_len > ast.extra_data.items.len - export_decl.specs_start) return false;

    for (ast.extra_data.items[export_decl.specs_start .. export_decl.specs_start + export_decl.specs_len]) |raw_spec_idx| {
        if (raw_spec_idx >= ast.nodes.items.len) return false;
        const specifier = ast.nodes.items[raw_spec_idx];
        if (specifier.tag != .export_specifier) return false;
        const local_idx = specifier.data.binary.left;
        if (local_idx.isNone() or @backingInt(local_idx) >= ast.nodes.items.len or
            ast.getNode(local_idx).tag != .identifier_reference) return false;

        const exported_idx = specifier.data.binary.right;
        if (!exported_idx.isNone() and
            (@backingInt(exported_idx) >= ast.nodes.items.len or
                ast.getNode(exported_idx).tag != .identifier_reference)) return false;
    }
    return true;
}

/// Top-level local export lists retain their local references, while a narrow
/// static named re-export subset preserves its loader record through lowering.
/// Namespace exports, attributes, and string names still require the full
/// graph resync path.
fn hasSupportedTopLevelExportDeclarations(module: *const Module) bool {
    const ast = &(module.ast orelse return false);
    const semantic = &(module.semantic orelse return false);
    var specifier_count: usize = 0;
    for (ast.nodes.items) |node| {
        if (node.tag == .export_specifier) specifier_count += 1;
    }
    if (ast.nodes.items.len == 0) return false;

    const root_idx = ast.transformed_root orelse @as(
        ast_mod.NodeIndex,
        @fromBackingInt(@intCast(@as(u32, @intCast(ast.nodes.items.len - 1)))),
    );
    if (root_idx.isNone() or @backingInt(root_idx) >= ast.nodes.items.len) return false;
    const root = ast.getNode(root_idx);
    if (root.tag != .program) return false;

    const extras = ast.extra_data.items;
    const statements = root.data.list;
    if (statements.start > extras.len or statements.len > extras.len - statements.start) return false;

    var safe_specifier_count: usize = 0;
    for (extras[statements.start .. statements.start + statements.len]) |raw_stmt_idx| {
        if (raw_stmt_idx >= ast.nodes.items.len) return false;
        const statement = ast.getNode(@fromBackingInt(@intCast(raw_stmt_idx)));
        if (statement.tag != .export_named_declaration) continue;

        const extra_start = statement.data.extra;
        if (extra_start > extras.len or extras.len - extra_start < 6) return false;
        const export_decl = module_parser.readExportNamedExtras(ast, extra_start);
        if (export_decl.specs_len == 0 and export_decl.decl.isNone() and
            !export_decl.source.isNone())
        {
            if (!isSupportedStaticNamedReExport(ast, export_decl)) return false;
            continue;
        }
        if (export_decl.specs_len == 0) continue;
        if (!export_decl.decl.isNone()) return false;
        if (export_decl.specs_start > extras.len or
            export_decl.specs_len > extras.len - export_decl.specs_start) return false;

        if (!export_decl.source.isNone()) {
            if (!isSupportedStaticNamedReExport(ast, export_decl)) return false;
            safe_specifier_count += export_decl.specs_len;
            continue;
        }

        for (extras[export_decl.specs_start .. export_decl.specs_start + export_decl.specs_len]) |raw_spec_idx| {
            if (raw_spec_idx >= ast.nodes.items.len) return false;
            const specifier = ast.getNode(@fromBackingInt(@intCast(raw_spec_idx)));
            if (specifier.tag != .export_specifier) return false;
            if ((specifier.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) {
                safe_specifier_count += 1;
                continue;
            }

            const local_idx = specifier.data.binary.left;
            if (local_idx.isNone() or @backingInt(local_idx) >= ast.nodes.items.len) return false;
            if (ast.getNode(local_idx).tag != .identifier_reference) return false;

            const local_raw = @backingInt(local_idx);
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
                if (@backingInt(exported_idx) >= ast.nodes.items.len) return false;
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
        if (child_idx.isNone() or @backingInt(child_idx) >= ast.nodes.items.len) continue;
        if (ast.nodes.items[@backingInt(child_idx)].tag == .spread_element) return true;
    }
    return false;
}

fn hasOnlyRetainableSpreadOperands(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node: ast_mod.Node,
) bool {
    const extras = ast.extra_data.items;
    var direct_identifier_callee: ?ast_mod.NodeIndex = null;
    var simple_member_callee: ?ast_mod.NodeIndex = null;
    const start: u32, const len: u32 = switch (node.tag) {
        .array_expression => .{ node.data.list.start, node.data.list.len },
        .call_expression, .new_expression => blk: {
            const extra = node.data.extra;
            if (extra > extras.len or extras.len - extra <= 3) return false;
            const callee: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
            if (callee.isNone() or @backingInt(callee) >= ast.nodes.items.len) return false;
            const callee_node = ast.nodes.items[@backingInt(callee)];
            if (callee_node.tag == .identifier_reference) {
                direct_identifier_callee = callee;
            } else if (node.tag == .call_expression and
                (callee_node.tag == .static_member_expression or callee_node.tag == .computed_member_expression))
            {
                // lowerSpreadCall clones a simple receiver identifier and
                // registers that second reference with its exact source SID.
                // Computed keys are read only once as part of the callee.
                // Keep optional, nested, and effectful shapes on reanalysis
                // until their distinct graph edits are audited.
                const member_extra = callee_node.data.extra;
                if (member_extra > extras.len or extras.len - member_extra < 3 or extras[member_extra + 2] != 0)
                    return false;
                const receiver: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[member_extra]));
                const property: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[member_extra + 1]));
                if (receiver.isNone() or @backingInt(receiver) >= ast.nodes.items.len or
                    ast.nodes.items[@backingInt(receiver)].tag != .identifier_reference or
                    !isBoundSourceIdentifierReference(ast, semantic, receiver) or
                    property.isNone() or @backingInt(property) >= ast.nodes.items.len) return false;
                const property_node = ast.nodes.items[@backingInt(property)];
                const safe_property = switch (callee_node.tag) {
                    .static_member_expression => property_node.tag == .identifier_reference,
                    .computed_member_expression => switch (property_node.tag) {
                        .identifier_reference => isBoundSourceIdentifierReference(ast, semantic, property),
                        .string_literal, .numeric_literal => true,
                        else => false,
                    },
                    else => false,
                };
                if (!safe_property) return false;
                simple_member_callee = callee;
            } else return false;
            break :blk .{ extras[extra + 1], extras[extra + 2] };
        },
        else => return false,
    };
    if (start > extras.len or len > extras.len - start) return false;
    if (node.tag == .call_expression or node.tag == .new_expression) {
        if (direct_identifier_callee) |callee| {
            if (!isBoundSourceIdentifierReference(ast, semantic, callee)) return false;
        } else if (node.tag != .call_expression or simple_member_callee == null) return false;
        const expression_extra = node.data.extra;
        if (expression_extra > extras.len or extras.len - expression_extra <= 3) return false;
        const expression_flags = extras[expression_extra + 3];
        if (node.tag == .call_expression and
            (expression_flags & ast_mod.CallFlags.optional_chain) != 0) return false;
        if (node.tag == .new_expression and
            (expression_flags & ast_mod.CallFlags.callee_optional_chain) != 0) return false;
    }

    for (extras[start .. start + len]) |raw_idx| {
        if (raw_idx >= ast.nodes.items.len) return false;
        const element = ast.nodes.items[raw_idx];
        if (element.tag != .spread_element) continue;
        const operand = element.data.unary.operand;
        if (operand.isNone() or @backingInt(operand) >= ast.nodes.items.len) return false;
        const operand_node = ast.nodes.items[@backingInt(operand)];
        if (operand_node.tag == .identifier_reference) {
            // Array literals need only the exact helper reference. Direct,
            // simple-member, and constructor calls also need bound source
            // references so the retained graph covers the complete call.
            // Other callees and unresolved operands stay on reanalysis.
            if (!isBoundSourceIdentifierReference(ast, semantic, operand)) return false;
            if (node.tag != .array_expression and node.tag != .call_expression and
                node.tag != .new_expression)
            {
                return false;
            }
            continue;
        }
        if (operand_node.tag != .array_expression) return false;
        const members = operand_node.data.list;
        if (members.start > extras.len or members.len > extras.len - members.start) return false;
        for (extras[members.start .. members.start + members.len]) |member_idx| {
            if (member_idx >= ast.nodes.items.len) return false;
            const member_tag = ast.nodes.items[member_idx].tag;
            // A literal hole is not an array value. `concat` keeps holes while
            // iterator spread materializes them as undefined, so leave this
            // shape outside the audited helper-free lowering subset.
            if (member_tag == .spread_element or member_tag == .elision) return false;
        }
    }
    return true;
}

fn hasReachableObjectSpread(ast: *const ast_mod.Ast) ?bool {
    const reachable_nodes = ast_walk.collectReachableNodeIndices(ast.allocator, ast) catch return null;
    defer ast.allocator.free(reachable_nodes);
    for (reachable_nodes) |raw_idx| {
        const node = ast.nodes.items[raw_idx];
        if (node.tag == .jsx_spread_attribute or
            (node.tag == .object_expression and hasDirectSpreadElement(ast, node))) return true;
    }
    return false;
}

fn hasReachableExponentiation(ast: *const ast_mod.Ast) ?bool {
    const reachable_nodes = ast_walk.collectReachableNodeIndices(ast.allocator, ast) catch return null;
    defer ast.allocator.free(reachable_nodes);
    for (reachable_nodes) |raw_idx| {
        const node = ast.nodes.items[raw_idx];
        const is_binary_exponentiation = node.tag == .binary_expression and
            node.data.binary.flags == @backingInt(token_mod.Kind.star2);
        const is_exponentiation_assignment = node.tag == .assignment_expression and
            node.data.binary.flags == @backingInt(token_mod.Kind.star2_eq);
        if (is_binary_exponentiation or is_exponentiation_assignment) return true;
    }
    return false;
}

// Super property lowering can add a runtime helper module. Scan nested nodes
// conservatively so each owner can be checked against the retained home graph.
fn methodHasSuperExpression(ast: *const ast_mod.Ast, method: ast_mod.Node) bool {
    if (method.tag != .method_definition) return true;
    const extra = method.data.extra;
    if (extra > ast.extra_data.items.len or
        ast.extra_data.items.len - extra <= ast_mod.MethodExtra.body) return true;
    const roots = [_]ast_mod.NodeIndex{
        @fromBackingInt(@intCast(ast.extra_data.items[extra + ast_mod.MethodExtra.params])),
        @fromBackingInt(@intCast(ast.extra_data.items[extra + ast_mod.MethodExtra.body])),
    };
    for (roots) |root| {
        if (root.isNone() or @backingInt(root) >= ast.nodes.items.len) return true;
        const descendants = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, root) catch return true;
        defer ast.allocator.free(descendants);
        for (descendants) |raw_idx| {
            if (ast.nodes.items[raw_idx].tag == .super_expression) return true;
        }
    }
    return false;
}

// The class async-method `super` path moves the method body into a generated
// state-machine callback. Keep only uses in the method's own body, where the
// class lowering context can attach the exact home-object binding. A `super`
// use in parameters or a nested function/arrow needs its own capture proof.
fn methodSuperUsesOnlyDirectMethodBody(ast: *const ast_mod.Ast, method: ast_mod.Node) bool {
    if (method.tag != .method_definition) return false;
    const extra = method.data.extra;
    if (extra > ast.extra_data.items.len or
        ast.extra_data.items.len - extra <= ast_mod.MethodExtra.body) return false;
    const params_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra + ast_mod.MethodExtra.params]));
    const body_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra + ast_mod.MethodExtra.body]));
    if (params_idx.isNone() or @backingInt(params_idx) >= ast.nodes.items.len or
        body_idx.isNone() or @backingInt(body_idx) >= ast.nodes.items.len) return false;

    const params_nodes = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, params_idx) catch return false;
    defer ast.allocator.free(params_nodes);
    for (params_nodes) |raw_idx| {
        if (raw_idx >= ast.nodes.items.len or ast.nodes.items[raw_idx].tag == .super_expression) return false;
    }

    const Work = struct { node: ast_mod.NodeIndex, nested_function: bool };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(ast.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(ast.allocator);
    stack.append(ast.allocator, .{ .node = body_idx, .nested_function = false }) catch return false;
    var found_super = false;
    while (stack.pop()) |work| {
        if (work.node.isNone() or @backingInt(work.node) >= ast.nodes.items.len) return false;
        const raw_idx = @backingInt(work.node);
        if (seen.contains(raw_idx)) continue;
        seen.put(ast.allocator, raw_idx, {}) catch return false;
        const node = ast.nodes.items[raw_idx];
        const nested_function = work.nested_function or switch (node.tag) {
            .arrow_function_expression,
            .function_declaration,
            .function_expression,
            .function,
            .method_definition,
            .class_declaration,
            .class_expression,
            => true,
            else => false,
        };
        if (node.tag == .super_expression) {
            if (nested_function) return false;
            found_super = true;
            continue;
        }
        var children = ast_walk.children(ast, node);
        while (children.next()) |child| {
            if (!child.isNone()) stack.append(ast.allocator, .{
                .node = child,
                .nested_function = nested_function,
            }) catch return false;
        }
    }
    return found_super;
}

// A class async method can keep its home-object graph when every `super` use
// belongs to audited arrow scopes at one uniform lexical depth below the
// method. Async arrows on every path to `super` must keep their own state
// machines, and each owner receives a separate preflight.
fn methodSuperUsesOnlyArrowScopes(
    ast: *const ast_mod.Ast,
    method: ast_mod.Node,
    expected_async: bool,
    expected_arrow_depth: ?u8,
    allow_multiple_owners: bool,
) bool {
    if (method.tag != .method_definition) return false;
    const extra = method.data.extra;
    if (extra > ast.extra_data.items.len or
        ast.extra_data.items.len - extra <= ast_mod.MethodExtra.body) return false;
    const params_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra + ast_mod.MethodExtra.params]));
    const body_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra + ast_mod.MethodExtra.body]));
    if (params_idx.isNone() or @backingInt(params_idx) >= ast.nodes.items.len or
        body_idx.isNone() or @backingInt(body_idx) >= ast.nodes.items.len) return false;

    const params_nodes = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, params_idx) catch return false;
    defer ast.allocator.free(params_nodes);
    for (params_nodes) |raw_idx| {
        if (raw_idx >= ast.nodes.items.len or ast.nodes.items[raw_idx].tag == .super_expression) return false;
    }

    const Work = struct {
        node: ast_mod.NodeIndex,
        arrow_depth: u8 = 0,
        arrow_owner: ?u32 = null,
        arrow_chain_is_async: bool = true,
        nested_non_arrow_function: bool = false,
    };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(ast.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(ast.allocator);
    stack.append(ast.allocator, .{ .node = body_idx }) catch return false;
    var super_arrow_owner: ?u32 = null;
    var observed_super_arrow_depth: ?u8 = null;
    while (stack.pop()) |work| {
        if (work.node.isNone() or @backingInt(work.node) >= ast.nodes.items.len) return false;
        const raw_idx = @backingInt(work.node);
        if (seen.contains(raw_idx)) continue;
        seen.put(ast.allocator, raw_idx, {}) catch return false;
        const node = ast.nodes.items[raw_idx];

        if (node.tag == .arrow_function_expression) {
            const arrow_extra = node.data.extra;
            if (arrow_extra > ast.extra_data.items.len or
                ast.extra_data.items.len - arrow_extra <= ast_mod.ArrowExtra.params or
                ast.extra_data.items.len - arrow_extra <= ast_mod.ArrowExtra.flags) return false;
            const arrow_params: ast_mod.NodeIndex = @fromBackingInt(@intCast(
                ast.extra_data.items[arrow_extra + ast_mod.ArrowExtra.params],
            ));
            if (!arrow_params.isNone()) {
                if (@backingInt(arrow_params) >= ast.nodes.items.len) return false;
                const arrow_params_nodes = ast_walk.collectReachableNodeIndicesFrom(
                    ast.allocator,
                    ast,
                    arrow_params,
                ) catch return false;
                var arrow_params_have_super = false;
                for (arrow_params_nodes) |parameter_raw_idx| {
                    if (parameter_raw_idx >= ast.nodes.items.len or
                        ast.nodes.items[parameter_raw_idx].tag == .super_expression)
                    {
                        arrow_params_have_super = true;
                        break;
                    }
                }
                ast.allocator.free(arrow_params_nodes);
                if (arrow_params_have_super) {
                    // A direct async arrow's parameter defaults are evaluated
                    // before its state-machine body is created. Preserve this
                    // one home-object read shape when its exact source scope
                    // remains on the class method graph. The super-use check
                    // below verifies the arrow chain is async. Nested parameter
                    // owners and sync-arrow defaults still require reanalysis.
                    if (!expected_async or work.arrow_depth != 0) return false;
                }
            }
        }

        if (node.tag == .super_expression) {
            if (work.nested_non_arrow_function) return false;
            if (expected_arrow_depth) |expected| {
                if (work.arrow_depth != expected) return false;
            } else {
                if (work.arrow_depth == 0) return false;
                if (observed_super_arrow_depth) |observed| {
                    if (observed != work.arrow_depth) return false;
                } else {
                    observed_super_arrow_depth = work.arrow_depth;
                }
            }
            if (expected_async and !work.arrow_chain_is_async) return false;
            const arrow_raw = work.arrow_owner orelse return false;
            if (arrow_raw >= ast.nodes.items.len or
                ast.nodes.items[arrow_raw].tag != .arrow_function_expression) return false;
            const arrow_extra = ast.nodes.items[arrow_raw].data.extra;
            if (arrow_extra > ast.extra_data.items.len or
                ast.extra_data.items.len - arrow_extra <= ast_mod.ArrowExtra.flags) return false;
            const arrow_is_async =
                (ast.extra_data.items[arrow_extra + ast_mod.ArrowExtra.flags] &
                    ast_mod.ArrowFlags.is_async) != 0;
            if (arrow_is_async != expected_async) return false;
            if (super_arrow_owner) |first_owner| {
                if (first_owner != arrow_raw and !allow_multiple_owners) return false;
            } else {
                super_arrow_owner = arrow_raw;
            }
            continue;
        }

        const nested_non_arrow_function = work.nested_non_arrow_function or switch (node.tag) {
            .function_declaration,
            .function_expression,
            .function,
            .method_definition,
            .class_declaration,
            .class_expression,
            => true,
            else => false,
        };
        const is_arrow = node.tag == .arrow_function_expression;
        if (is_arrow and work.arrow_depth == std.math.maxInt(u8)) return false;
        const arrow_depth = if (is_arrow) work.arrow_depth + 1 else work.arrow_depth;
        const arrow_owner = if (is_arrow) @as(?u32, raw_idx) else work.arrow_owner;
        const arrow_is_async = is_arrow and
            (ast.extra_data.items[node.data.extra + ast_mod.ArrowExtra.flags] &
                ast_mod.ArrowFlags.is_async) != 0;
        const arrow_chain_is_async = work.arrow_chain_is_async and
            (!is_arrow or arrow_is_async);
        var children = ast_walk.children(ast, node);
        while (children.next()) |child| {
            if (!child.isNone()) stack.append(ast.allocator, .{
                .node = child,
                .arrow_depth = arrow_depth,
                .arrow_owner = arrow_owner,
                .arrow_chain_is_async = arrow_chain_is_async,
                .nested_non_arrow_function = nested_non_arrow_function,
            }) catch return false;
        }
    }
    return super_arrow_owner != null;
}

fn methodSuperUsesOnlySingleSyncArrow(ast: *const ast_mod.Ast, method: ast_mod.Node) bool {
    return methodSuperUsesOnlyArrowScopes(ast, method, false, 1, false);
}

fn methodSuperUsesOnlyUniformAsyncArrowScopes(ast: *const ast_mod.Ast, method: ast_mod.Node) bool {
    return methodSuperUsesOnlyArrowScopes(ast, method, true, null, true);
}

fn hasValidSourceSymbol(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
    expected_tag: NodeTag,
) bool {
    if (node_idx.isNone() or @backingInt(node_idx) >= ast.nodes.items.len or
        ast.getNode(node_idx).tag != expected_tag) return false;
    const raw_idx = @backingInt(node_idx);
    if (raw_idx >= semantic.symbol_ids.len) return false;
    const symbol_raw = semantic.symbol_ids[raw_idx] orelse return false;
    if (symbol_raw >= semantic.symbols.items.len) return false;
    const scope_id = semantic.symbols.items[symbol_raw].scope_id;
    return !scope_id.isNone() and @backingInt(scope_id) < semantic.scopes.len;
}

fn isBoundSourceIdentifierReference(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
) bool {
    return hasValidSourceSymbol(ast, semantic, node_idx, .identifier_reference);
}

/// An unresolved source identifier has no SymbolId to relocate. Its spelling
/// remains reserved in the retained semantic graph, so a simple static-field
/// initializer can keep this exact external reference without reanalysis.
fn isUnresolvedSourceIdentifierReference(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
) bool {
    if (node_idx.isNone() or @backingInt(node_idx) >= ast.nodes.items.len) return false;
    const raw_idx = @backingInt(node_idx);
    const node = ast.nodes.items[raw_idx];
    if (node.tag != .identifier_reference or raw_idx >= semantic.symbol_ids.len or
        semantic.symbol_ids[raw_idx] != null) return false;
    return semantic.unresolved_references.contains(ast.getText(node.span));
}

/// Global `undefined` is immutable; other unresolved names remain on reanalysis.
fn isUnresolvedGlobalUndefinedReference(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
) bool {
    if (!isUnresolvedSourceIdentifierReference(ast, semantic, node_idx)) return false;
    return std.mem.eql(u8, ast.getText(ast.getNode(node_idx).span), "undefined");
}

/// `var` and function bindings are initialized by scope instantiation, so
/// `typeof` and `void` cannot observe a lexical TDZ while preserving the exact SID.
fn isInitializedSourceIdentifierReference(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
) bool {
    if (!hasValidSourceSymbol(ast, semantic, node_idx, .identifier_reference)) return false;
    const raw_idx = @backingInt(node_idx);
    const symbol_raw = semantic.symbol_ids[raw_idx] orelse return false;
    const kind = semantic.symbols.items[symbol_raw].kind;
    return kind == .variable_var or kind == .function_decl;
}

/// A synchronous function expression is discarded by `typeof` and `void`.
/// Its body is not evaluated, so these operators cannot observe its captures,
/// parameters, or local declarations while the surrounding graph is retained.
fn isDiscardedSynchronousFunctionExpression(
    ast: *const ast_mod.Ast,
    node_idx: ast_mod.NodeIndex,
) bool {
    var current_idx = node_idx;
    var hops: usize = 0;
    while (hops <= ast.nodes.items.len) : (hops += 1) {
        if (current_idx.isNone() or @backingInt(current_idx) >= ast.nodes.items.len) return false;
        const node = ast.getNode(current_idx);
        if (node.tag == .parenthesized_expression) {
            current_idx = node.data.unary.operand;
            continue;
        }
        if (node.tag != .function_expression) return false;
        const flags_at = node.data.extra + ast_mod.FunctionExtra.flags;
        if (flags_at >= ast.extra_data.items.len) return false;
        const flags = ast.extra_data.items[flags_at];
        return (flags & (ast_mod.FunctionFlags.is_async | ast_mod.FunctionFlags.is_generator)) == 0;
    }
    return false;
}

fn isBoundSourceIdentifierBinding(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
) bool {
    return hasValidSourceSymbol(ast, semantic, node_idx, .binding_identifier);
}

fn isBoundSourceIdentifierAssignmentTarget(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
) bool {
    return hasValidSourceSymbol(ast, semantic, node_idx, .assignment_target_identifier);
}

/// Keep nested ordinary source-call chains rooted at a bound source identifier
/// and exclude optional calls and other callee shapes from the chain.
fn isRetainableBoundSourceCallCalleeChain(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    callee_idx: ast_mod.NodeIndex,
) bool {
    var current = callee_idx;
    while (true) {
        if (current.isNone() or @backingInt(current) >= ast.nodes.items.len) return false;
        const callee = ast.getNode(current);
        if (callee.tag == .identifier_reference)
            return isBoundSourceIdentifierReference(ast, semantic, current);
        if (callee.tag != .call_expression) return false;
        const extra = callee.data.extra;
        if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 3) return false;
        if ((ast.extra_data.items[extra + 3] & ast_mod.CallFlags.optional_chain) != 0) return false;
        current = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
    }
}

/// Optional-member chains can use an exact bound source identifier or an
/// unresolved external identifier as their root. Call receivers use the
/// separate exact-callee checks below; computed optional member segments are
/// traversed only as part of this chain.
fn isRetainableOptionalMemberReceiver(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    receiver_idx: ast_mod.NodeIndex,
    allow_unresolved_root: bool,
) bool {
    if (ast.has_jsx) return false;
    var current = receiver_idx;
    while (true) {
        if (current.isNone() or @backingInt(current) >= ast.nodes.items.len) return false;
        const receiver = ast.getNode(current);
        switch (receiver.tag) {
            .identifier_reference => return isBoundSourceIdentifierReference(ast, semantic, current) or
                (allow_unresolved_root and isUnresolvedSourceIdentifierReference(ast, semantic, current)),
            .static_member_expression, .computed_member_expression => {
                const extra = receiver.data.extra;
                if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 2)
                    return false;
                if ((ast.extra_data.items[extra + 2] & ast_mod.MemberFlags.optional_chain) == 0)
                    return false;
                current = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
            },
            .call_expression => {
                const extra = receiver.data.extra;
                if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 3)
                    return false;
                if ((ast.extra_data.items[extra + 3] & ast_mod.CallFlags.optional_chain) != 0)
                    return isRetainableOptionalCall(ast, semantic, current);
                const callee: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
                return isRetainableBoundSourceCallCalleeChain(ast, semantic, callee);
            },
            else => return false,
        }
    }
}

fn isRetainableOptionalMemberAccess(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
    allow_unresolved_root: bool,
) bool {
    if (node_idx.isNone() or @backingInt(node_idx) >= ast.nodes.items.len) return false;
    const node = ast.getNode(node_idx);
    if (node.tag != .static_member_expression and node.tag != .computed_member_expression) return false;
    const extra = node.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 2) return false;
    if ((ast.extra_data.items[extra + 2] & ast_mod.MemberFlags.optional_chain) == 0) return false;
    const receiver: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
    // The optional-chain transform captures this receiver into an exact temp.
    return isRetainableOptionalMemberReceiver(ast, semantic, receiver, allow_unresolved_root);
}

/// An ordinary member/call tail can follow one audited optional member access
/// or optional call. The optional segment must pass the same exact source-root
/// checks as its standalone form.
fn isRetainableOptionalMemberChainTail(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
) bool {
    var current = node_idx;
    while (true) {
        if (current.isNone() or @backingInt(current) >= ast.nodes.items.len) return false;
        const node = ast.getNode(current);
        switch (node.tag) {
            .static_member_expression, .computed_member_expression => {
                const extra = node.data.extra;
                if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 2)
                    return false;
                const receiver: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
                const optional = (ast.extra_data.items[extra + 2] & ast_mod.MemberFlags.optional_chain) != 0;
                if (optional) return isRetainableOptionalMemberReceiver(ast, semantic, receiver, true);
                current = receiver;
            },
            .call_expression => {
                const extra = node.data.extra;
                if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 3)
                    return false;
                if ((ast.extra_data.items[extra + 3] & ast_mod.CallFlags.optional_chain) != 0) {
                    // An exact source-rooted optional call can terminate the
                    // chain before an ordinary member tail, as in
                    // `getReceiver()?.method?.().value`. Keep the same source
                    // identity gate used by standalone optional calls.
                    return isRetainableOptionalCall(ast, semantic, current);
                }
                current = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
            },
            else => return false,
        }
    }
}

fn isRetainableOptionalChainMemberAccess(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
) bool {
    if (node_idx.isNone() or @backingInt(node_idx) >= ast.nodes.items.len) return false;
    const node = ast.getNode(node_idx);
    if (node.tag != .static_member_expression and node.tag != .computed_member_expression) return false;
    const extra = node.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 2) return false;
    const receiver: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
    if ((ast.extra_data.items[extra + 2] & ast_mod.MemberFlags.optional_chain) != 0)
        return isRetainableOptionalMemberReceiver(ast, semantic, receiver, true);
    return isRetainableOptionalMemberChainTail(ast, semantic, receiver);
}

/// An ordinary call may continue a retained optional call result, but only
/// when the callee spine reaches an optional call that passes the same exact
/// source-rooted checks as a standalone optional call.
fn isRetainableOptionalCallResultTail(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    call_idx: ast_mod.NodeIndex,
) bool {
    var current = call_idx;
    while (true) {
        if (current.isNone() or @backingInt(current) >= ast.nodes.items.len) return false;
        const call = ast.getNode(current);
        if (call.tag != .call_expression) return false;
        const extra = call.data.extra;
        if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 3) return false;
        const callee: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
        if ((ast.extra_data.items[extra + 3] & ast_mod.CallFlags.optional_chain) != 0)
            return isRetainableOptionalCall(ast, semantic, current);
        current = callee;
    }
}

fn isRetainableOptionalCall(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
) bool {
    if (node_idx.isNone() or @backingInt(node_idx) >= ast.nodes.items.len) return false;
    const call = ast.getNode(node_idx);
    if (call.tag != .call_expression) return false;
    const extra = call.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 3) return false;
    const optional_call = (ast.extra_data.items[extra + 3] & ast_mod.CallFlags.optional_chain) != 0;
    const callee: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
    if (callee.isNone() or @backingInt(callee) >= ast.nodes.items.len) return false;
    const member = ast.getNode(callee);
    if (member.tag == .identifier_reference) {
        return optional_call and isBoundSourceIdentifierReference(ast, semantic, callee);
    }
    if (member.tag == .call_expression) {
        if (optional_call) {
            // A later optional call may consume the result of an already
            // audited optional call, as in `factory()?.()?.()`. Keep the
            // source-root check at every optional segment; untracked roots
            // still fail both paths below.
            return isRetainableBoundSourceCallCalleeChain(ast, semantic, callee) or
                isRetainableOptionalCallResultTail(ast, semantic, callee);
        }
        // `method?.()()` keeps the optional short-circuit around the complete
        // ordinary call tail and retains the source callee identity.
        return isRetainableOptionalCallResultTail(ast, semantic, callee);
    }
    if (member.tag != .static_member_expression and member.tag != .computed_member_expression) return false;
    const member_extra = member.data.extra;
    if (member_extra > ast.extra_data.items.len or ast.extra_data.items.len - member_extra <= 2) return false;
    const receiver: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[member_extra]));
    if ((ast.extra_data.items[member_extra + 2] & ast_mod.MemberFlags.optional_chain) != 0) {
        // An unresolved root is admitted for `root?.method()`, where only the
        // receiver is optional. Keep `root?.method?.()` on the stricter path.
        return isRetainableOptionalMemberAccess(ast, semantic, callee, !optional_call);
    }
    if (!optional_call) return isRetainableOptionalMemberChainTail(ast, semantic, callee);
    return isRetainableOptionalMemberReceiver(ast, semantic, receiver, false);
}

/// Compound/logical assignment lowering already records member receiver/key
/// temps in the edited graph. Admit ordinary member targets when they contain
/// no super/private access that takes a separate lowering path.
fn isRetainableAssignmentTarget(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
) bool {
    if (node_idx.isNone() or @backingInt(node_idx) >= ast.nodes.items.len) return false;
    const target = ast.getNode(node_idx);
    if (target.tag == .assignment_target_identifier)
        return isBoundSourceIdentifierAssignmentTarget(ast, semantic, node_idx);
    if (target.tag != .static_member_expression and target.tag != .computed_member_expression) return false;
    if (ast_mod.spineHasOptionalChain(ast, node_idx)) return false;

    var pending: std.ArrayList(ast_mod.NodeIndex) = .empty;
    defer pending.deinit(ast.allocator);
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(ast.allocator);
    pending.append(ast.allocator, node_idx) catch return false;
    while (pending.pop()) |current| {
        if (current.isNone() or @backingInt(current) >= ast.nodes.items.len) return false;
        const raw = @backingInt(current);
        if (visited.contains(raw)) continue;
        visited.put(ast.allocator, raw, {}) catch return false;
        const node = ast.nodes.items[raw];
        switch (node.tag) {
            .super_expression, .private_field_expression, .private_identifier => return false,
            else => {},
        }
        var children = ast_walk.children(ast, node);
        while (children.next()) |child| pending.append(ast.allocator, child) catch return false;
    }
    return true;
}

/// A direct `super` property access can keep its exact home-object identity
/// through the class/object super-property transformer. A caller may admit
/// optional computed-key transforms only when the full graph preflight checks
/// them; nested `super` and private access stay outside this proof.
fn isRetainableDirectSuperPropertyAccess(
    ast: *const ast_mod.Ast,
    node_idx: ast_mod.NodeIndex,
    allow_optional_computed_key: bool,
) bool {
    if (node_idx.isNone() or @backingInt(node_idx) >= ast.nodes.items.len) return false;
    const target = ast.getNode(node_idx);
    if (target.tag != .static_member_expression and target.tag != .computed_member_expression) return false;
    if (ast_mod.spineHasOptionalChain(ast, node_idx)) return false;

    const extra = target.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 2) return false;
    const receiver: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
    if (receiver.isNone() or @backingInt(receiver) >= ast.nodes.items.len or
        ast.getNode(receiver).tag != .super_expression) return false;
    if (target.tag == .static_member_expression) return true;

    const property: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra + 1]));
    if (property.isNone() or @backingInt(property) >= ast.nodes.items.len) return false;
    var pending: std.ArrayList(ast_mod.NodeIndex) = .empty;
    defer pending.deinit(ast.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(ast.allocator);
    pending.append(ast.allocator, property) catch return false;
    while (pending.pop()) |current| {
        if (current.isNone() or @backingInt(current) >= ast.nodes.items.len) return false;
        const raw = @backingInt(current);
        if (seen.contains(raw)) continue;
        seen.put(ast.allocator, raw, {}) catch return false;
        const node = ast.getNode(current);
        if (!allow_optional_computed_key and ast_mod.spineHasOptionalChain(ast, current)) return false;
        switch (node.tag) {
            .super_expression, .private_field_expression, .private_identifier => return false,
            else => {},
        }
        var children = ast_walk.children(ast, node);
        while (children.next()) |child| {
            if (!child.isNone()) pending.append(ast.allocator, child) catch return false;
        }
    }
    return true;
}

fn isSafeConstructorBinaryOperator(operator: token_mod.Kind) bool {
    return switch (operator) {
        .l_angle,
        .r_angle,
        .lt_eq,
        .gt_eq,
        .eq2,
        .neq,
        .eq3,
        .neq2,
        .plus,
        .minus,
        .star,
        .slash,
        .percent,
        => true,
        else => false,
    };
}

fn isSafeConstructorLogicalOperator(operator: token_mod.Kind) bool {
    return switch (operator) {
        .amp2, .pipe2 => true,
        else => false,
    };
}

fn isSafeConstructorNativeCompoundAssignmentOperator(operator: token_mod.Kind) bool {
    return switch (operator) {
        .plus_eq,
        .minus_eq,
        .star_eq,
        .slash_eq,
        .percent_eq,
        .amp_eq,
        .pipe_eq,
        .caret_eq,
        .shift_left_eq,
        .shift_right_eq,
        .shift_right3_eq,
        => true,
        else => false,
    };
}

fn isSafeConstructorUnaryOperator(operator: token_mod.Kind) bool {
    return switch (operator) {
        .plus, .minus, .bang, .tilde => true,
        else => false,
    };
}

fn isSafeConstructorValue(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    value_idx: ast_mod.NodeIndex,
) bool {
    if (value_idx.isNone() or @backingInt(value_idx) >= ast.nodes.items.len) return false;
    const value = ast.getNode(value_idx);
    if (value.tag == .binary_expression) {
        const operator: token_mod.Kind = @fromBackingInt(@intCast(value.data.binary.flags));
        return isSafeConstructorBinaryOperator(operator) and
            isSafeConstructorValue(ast, semantic, value.data.binary.left) and
            isSafeConstructorValue(ast, semantic, value.data.binary.right);
    }
    if (value.tag == .unary_expression) {
        const extras = ast.extra_data.items;
        const extra = value.data.extra;
        if (extra > extras.len or extras.len - extra < 2) return false;
        const operator: token_mod.Kind = @fromBackingInt(@intCast(@as(u8, @truncate(extras[extra + 1]))));
        const operand_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
        return isSafeConstructorUnaryOperator(operator) and
            isSafeConstructorValue(ast, semantic, operand_idx);
    }
    if (value.tag == .logical_expression) {
        const operator: token_mod.Kind = @fromBackingInt(@intCast(value.data.binary.flags));
        return isSafeConstructorLogicalOperator(operator) and
            isSafeConstructorValue(ast, semantic, value.data.binary.left) and
            isSafeConstructorValue(ast, semantic, value.data.binary.right);
    }
    if (value.tag == .conditional_expression) {
        return isSafeConstructorValue(ast, semantic, value.data.ternary.a) and
            isSafeConstructorValue(ast, semantic, value.data.ternary.b) and
            isSafeConstructorValue(ast, semantic, value.data.ternary.c);
    }
    return switch (value.tag) {
        .boolean_literal, .null_literal, .numeric_literal, .string_literal => true,
        .identifier_reference => isBoundSourceIdentifierReference(ast, semantic, value_idx),
        else => false,
    };
}

const ComputedMemberKeyCallMode = enum {
    disallowed,
    sequence_final,
    sequence_argument_member_read,
    sequence_argument_optional_key_call,
    sequence_argument_member_read_optional_nested_call,
    nested_call_argument,
};

const BoundCallArgumentDepth = enum {
    none,
    one,
    two,
};

const RetainableStaticFieldExpressionWorkItem = struct {
    expression_idx: ast_mod.NodeIndex,
    allow_optional_invocations: bool,
    allow_nested_call_callees: bool,
};

/// A non-optional member chain can be retained when it starts at an exact
/// source binding or unresolved source identifier. Computed keys may be safe
/// bound values, unresolved identifiers, or calls that the shared expression
/// worklist validates. The node-count bound rejects malformed cycles.
fn enqueueRetainableStaticFieldMemberKeyCalls(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    member_idx: ast_mod.NodeIndex,
    pending: *std.ArrayList(RetainableStaticFieldExpressionWorkItem),
) bool {
    if (member_idx.isNone() or @backingInt(member_idx) >= ast.nodes.items.len) return false;
    const extras = ast.extra_data.items;
    var current_idx = member_idx;
    var saw_member = false;
    var remaining_nodes = ast.nodes.items.len;
    while (remaining_nodes > 0) : (remaining_nodes -= 1) {
        if (current_idx.isNone() or @backingInt(current_idx) >= ast.nodes.items.len) return false;
        const current = ast.getNode(current_idx);
        if (current.tag == .identifier_reference)
            return saw_member and (isBoundSourceIdentifierReference(ast, semantic, current_idx) or
                isUnresolvedSourceIdentifierReference(ast, semantic, current_idx));
        if (current.tag != .static_member_expression and current.tag != .computed_member_expression) return false;

        const extra = current.data.extra;
        if (extra > extras.len or extras.len - extra < 3 or extras[extra + 2] != 0) return false;
        const object_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
        const property_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + 1]));
        if (object_idx.isNone() or @backingInt(object_idx) >= ast.nodes.items.len or
            property_idx.isNone() or @backingInt(property_idx) >= ast.nodes.items.len) return false;
        if (current.tag == .static_member_expression) {
            if (ast.getNode(property_idx).tag != .identifier_reference) return false;
        } else if (!isSafeConstructorValue(ast, semantic, property_idx) and
            !isUnresolvedSourceIdentifierReference(ast, semantic, property_idx))
        {
            if (ast.getNode(property_idx).tag != .call_expression) return false;
            pending.append(allocator, .{
                .expression_idx = property_idx,
                .allow_optional_invocations = false,
                .allow_nested_call_callees = false,
            }) catch return false;
        }
        saw_member = true;
        current_idx = object_idx;
    }
    return false;
}

/// Optional static-field member chains can stay on the edited graph when
/// their segments are dot reads or optional computed reads with safe values
/// or call keys admitted by the shared validator. A computed key can also be
/// an unresolved external identifier when the chain has an unresolved root.
/// A bounded effectful sequence key requires a bound or unresolved root and
/// exact-bound prefix calls. Callers control whether an unresolved identifier
/// may be the root.
fn isRetainableStaticFieldOptionalMemberChain(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    member_idx: ast_mod.NodeIndex,
    allow_unresolved_root: bool,
    allow_call_result_root: bool,
) bool {
    const extras = ast.extra_data.items;
    var current_idx = member_idx;
    var saw_optional = false;
    var remaining_nodes = ast.nodes.items.len;
    while (remaining_nodes > 0) : (remaining_nodes -= 1) {
        if (current_idx.isNone() or @backingInt(current_idx) >= ast.nodes.items.len) return false;
        const member = ast.getNode(current_idx);
        if (member.tag == .identifier_reference)
            return saw_optional and (isBoundSourceIdentifierReference(ast, semantic, current_idx) or
                (allow_unresolved_root and
                    isUnresolvedSourceIdentifierReference(ast, semantic, current_idx)));
        if (member.tag == .call_expression) {
            if (!saw_optional or !allow_call_result_root) return false;
            const call_extra = member.data.extra;
            if (call_extra > extras.len or extras.len - call_extra < 4 or
                (extras[call_extra + 3] & ast_mod.CallFlags.optional_chain) != 0) return false;
            const call_callee: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[call_extra]));
            return isRetainableBoundSourceCallCalleeChain(ast, semantic, call_callee) and
                isRetainableStaticFieldCall(allocator, ast, semantic, current_idx, false, false, false);
        }
        if (member.tag != .static_member_expression and member.tag != .computed_member_expression)
            return false;
        const extra = member.data.extra;
        if (extra > extras.len or extras.len - extra < 3) return false;
        const flags = extras[extra + 2];
        if (member.tag == .computed_member_expression) {
            if (flags != ast_mod.MemberFlags.optional_chain) return false;
            saw_optional = true;
        } else if (flags == ast_mod.MemberFlags.optional_chain) {
            saw_optional = true;
        } else if (flags != 0) {
            return false;
        }
        const receiver_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
        const property_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + 1]));
        if (receiver_idx.isNone() or @backingInt(receiver_idx) >= ast.nodes.items.len or
            property_idx.isNone() or @backingInt(property_idx) >= ast.nodes.items.len)
        {
            return false;
        }
        const property = ast.getNode(property_idx);
        if (member.tag == .static_member_expression) {
            if (property.tag != .identifier_reference) return false;
        } else if (!isSafeConstructorValue(ast, semantic, property_idx)) {
            const unresolved_external_root = allow_unresolved_root and
                hasUnresolvedStaticFieldMemberChainRoot(ast, semantic, member_idx);
            const bound_source_root = hasBoundStaticFieldMemberChainRoot(ast, semantic, member_idx);
            const unresolved_external_key = unresolved_external_root and
                isRetainableUnresolvedStaticFieldIdentifier(ast, semantic, property_idx);
            const retained_effectful_sequence_key = (unresolved_external_root or bound_source_root) and
                isRetainableBoundStaticFieldSequenceExpression(
                    ast,
                    semantic,
                    property_idx,
                    unresolved_external_root,
                    false,
                    .disallowed,
                    false,
                );
            if (!unresolved_external_key and !retained_effectful_sequence_key and
                (property.tag != .call_expression or
                    !isRetainableStaticFieldExpression(allocator, ast, semantic, property_idx, false, false, false))) return false;
        }
        current_idx = receiver_idx;
    }
    return false;
}

/// Safe static-field calls and computed keys are validated together on one
/// iterative worklist. This keeps deeply nested calls out of recursive helper
/// chains, rejects repeated nodes/cycles, and leaves the original AST intact so
/// evaluation order and a computed member callee's receiver (`this`) survive.
/// Optional invocations are admitted for static initializer call trees when
/// their direct identifier is safe or their member receiver is a bound source
/// identifier or retained unresolved external identifier and the member access
/// (including any computed key) is safe. A deep optional member receiver is
/// admitted only when the optional-call lowering can keep its null guard around
/// the complete method read and invocation. Unresolved optional receiver chains,
/// unbound receiver expressions or call-result callees, optional calls inside
/// computed keys and effectful arguments other than the bounded sequence form
/// admitted for optional member calls with a bound or unresolved root also stay
/// on reanalysis.
fn isRetainableUnresolvedStaticFieldIdentifier(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    identifier_idx: ast_mod.NodeIndex,
) bool {
    if (!isUnresolvedSourceIdentifierReference(ast, semantic, identifier_idx)) return false;
    return !std.mem.eql(u8, ast.getText(ast.getNode(identifier_idx).span), "require");
}

fn hasBoundStaticFieldDotCallCalleeRoot(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    callee_idx: ast_mod.NodeIndex,
) bool {
    const extras = ast.extra_data.items;
    var current_idx = callee_idx;
    var remaining_nodes = ast.nodes.items.len;
    while (remaining_nodes > 0) : (remaining_nodes -= 1) {
        if (current_idx.isNone() or @backingInt(current_idx) >= ast.nodes.items.len) return false;
        const current = ast.getNode(current_idx);
        if (current.tag == .identifier_reference)
            return isBoundSourceIdentifierReference(ast, semantic, current_idx);
        if (current.tag != .static_member_expression) return false;
        const extra = current.data.extra;
        if (extra > extras.len or extras.len - extra < 3 or extras[extra + 2] != 0) return false;
        const object_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
        const property_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + 1]));
        if (object_idx.isNone() or @backingInt(object_idx) >= ast.nodes.items.len or
            property_idx.isNone() or @backingInt(property_idx) >= ast.nodes.items.len or
            ast.getNode(property_idx).tag != .identifier_reference) return false;
        current_idx = object_idx;
    }
    return false;
}

fn isRetainableBoundStaticFieldEffectCall(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    call_idx: ast_mod.NodeIndex,
    allow_computed_member_callee: bool,
    // Each caller explicitly gates optional calls and bounded exact-bound
    // call arguments for the edge it is validating.
    allow_optional_call: bool,
    bound_call_argument_depth: BoundCallArgumentDepth,
    // Nested argument calls may use safe computed-member callees, but not
    // effectful computed keys within those callees unless the bounded mode
    // explicitly admits one exact-bound key call.
    computed_member_key_call_mode: ComputedMemberKeyCallMode,
) bool {
    if (call_idx.isNone() or @backingInt(call_idx) >= ast.nodes.items.len) return false;
    const call = ast.getNode(call_idx);
    if (call.tag != .call_expression) return false;
    const extras = ast.extra_data.items;
    const extra = call.data.extra;
    if (extra > extras.len or extras.len - extra < 4) return false;
    const optional_call = (extras[extra + 3] & ast_mod.CallFlags.optional_chain) != 0;
    if (!allow_optional_call and optional_call) return false;
    const callee_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
    if (callee_idx.isNone() or @backingInt(callee_idx) >= ast.nodes.items.len) return false;
    const callee = ast.getNode(callee_idx);
    const bound_callee = switch (callee.tag) {
        .identifier_reference => isBoundSourceIdentifierReference(ast, semantic, callee_idx),
        .static_member_expression => hasBoundStaticFieldDotCallCalleeRoot(ast, semantic, callee_idx),
        .computed_member_expression => allow_computed_member_callee and
            isRetainableBoundStaticFieldMemberRead(
                ast,
                semantic,
                callee_idx,
                computed_member_key_call_mode,
            ),
        else => false,
    };
    if (!bound_callee) return false;
    const args_start = extras[extra + 1];
    const args_len = extras[extra + 2];
    if (args_start > extras.len or args_len > extras.len - args_start) return false;
    for (extras[args_start .. args_start + args_len]) |raw_arg| {
        if (raw_arg >= ast.nodes.items.len) return false;
        const argument_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw_arg));
        if (isSafeConstructorValue(ast, semantic, argument_idx)) continue;
        const nested_argument_depth: BoundCallArgumentDepth = switch (bound_call_argument_depth) {
            .none => return false,
            .one => .none,
            .two => .one,
        };
        const nested_key_call_mode: ComputedMemberKeyCallMode = if (bound_call_argument_depth == .two and
            (computed_member_key_call_mode == .sequence_argument_optional_key_call or
                computed_member_key_call_mode == .sequence_argument_member_read_optional_nested_call))
            .sequence_argument_member_read_optional_nested_call
        else
            .nested_call_argument;
        if (!isRetainableBoundStaticFieldEffectCall(
            ast,
            semantic,
            argument_idx,
            true,
            computed_member_key_call_mode == .sequence_final or
                computed_member_key_call_mode == .sequence_argument_optional_key_call or
                computed_member_key_call_mode == .sequence_argument_member_read_optional_nested_call,
            nested_argument_depth,
            nested_key_call_mode,
        )) return false;
    }
    return true;
}

/// Keep sequence expressions only when their non-final calls have exact-bound
/// callees and safe arguments. The final value is safe, a bounded exact-bound
/// member read/call, or may be unresolved when the caller has independently
/// proved the external-root context.
fn isRetainableBoundStaticFieldSequenceExpression(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    expression_idx: ast_mod.NodeIndex,
    allow_unresolved_last_value: bool,
    allow_bound_member_read_last_value: bool,
    member_read_key_call_mode: ComputedMemberKeyCallMode,
    allow_bound_call_last_value: bool,
) bool {
    if (expression_idx.isNone() or @backingInt(expression_idx) >= ast.nodes.items.len) return false;
    var current_idx = expression_idx;
    var remaining_nodes = ast.nodes.items.len;
    while (remaining_nodes > 0) : (remaining_nodes -= 1) {
        if (current_idx.isNone() or @backingInt(current_idx) >= ast.nodes.items.len) return false;
        const expression = ast.getNode(current_idx);
        if (expression.tag != .parenthesized_expression) break;
        current_idx = expression.data.unary.operand;
    }
    if (current_idx.isNone() or @backingInt(current_idx) >= ast.nodes.items.len) return false;
    const expression = ast.getNode(current_idx);
    if (expression.tag != .sequence_expression) return false;
    const list = expression.data.list;
    const extras = ast.extra_data.items;
    if (list.len < 2 or list.start > extras.len or list.len > extras.len - list.start) return false;
    for (extras[list.start .. list.start + list.len - 1]) |raw_item| {
        if (raw_item >= ast.nodes.items.len or
            !isRetainableBoundStaticFieldEffectCall(
                ast,
                semantic,
                @fromBackingInt(@intCast(raw_item)),
                false,
                false,
                .none,
                .disallowed,
            )) return false;
    }
    const last_raw = extras[list.start + list.len - 1];
    if (last_raw >= ast.nodes.items.len) return false;
    const last_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(last_raw));
    return isSafeConstructorValue(ast, semantic, last_idx) or
        (allow_bound_member_read_last_value and
            isRetainableBoundStaticFieldMemberRead(ast, semantic, last_idx, member_read_key_call_mode)) or
        (allow_bound_call_last_value and
            isRetainableBoundStaticFieldEffectCall(
                ast,
                semantic,
                last_idx,
                true,
                false,
                .one,
                .sequence_final,
            )) or
        (allow_unresolved_last_value and
            isRetainableUnresolvedStaticFieldIdentifier(ast, semantic, last_idx));
}

/// A sequence argument may end in a non-optional member read only when every
/// segment uses a safe key and the chain starts at an exact-bound source name.
/// Key calls are mode-gated: an ordinary computed-member key call at a
/// sequence-argument boundary may contain two exact-bound call-argument
/// levels. Optional key calls and final calls use shallower modes, and nested
/// computed callees cannot inherit the deeper mode.
fn isRetainableBoundStaticFieldMemberRead(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    member_idx: ast_mod.NodeIndex,
    key_call_mode: ComputedMemberKeyCallMode,
) bool {
    if (member_idx.isNone() or @backingInt(member_idx) >= ast.nodes.items.len or
        key_call_mode == .sequence_argument_member_read_optional_nested_call) return false;
    const extras = ast.extra_data.items;
    var current_idx = member_idx;
    var saw_member = false;
    var remaining_nodes = ast.nodes.items.len;
    while (remaining_nodes > 0) : (remaining_nodes -= 1) {
        if (current_idx.isNone() or @backingInt(current_idx) >= ast.nodes.items.len) return false;
        const current = ast.getNode(current_idx);
        if (current.tag == .identifier_reference)
            return saw_member and isBoundSourceIdentifierReference(ast, semantic, current_idx);
        if (current.tag != .static_member_expression and current.tag != .computed_member_expression)
            return false;
        const extra = current.data.extra;
        if (extra > extras.len or extras.len - extra < 3 or extras[extra + 2] != 0) return false;
        const receiver_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
        const property_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + 1]));
        if (receiver_idx.isNone() or @backingInt(receiver_idx) >= ast.nodes.items.len or
            property_idx.isNone() or @backingInt(property_idx) >= ast.nodes.items.len) return false;
        if (current.tag == .static_member_expression) {
            if (ast.getNode(property_idx).tag != .identifier_reference) return false;
        } else if (!isSafeConstructorValue(ast, semantic, property_idx)) {
            if (key_call_mode == .disallowed or
                ast.getNode(property_idx).tag != .call_expression) return false;
            const key_call_extra = ast.getNode(property_idx).data.extra;
            if (key_call_extra > extras.len or extras.len - key_call_extra < 4) return false;
            const optional_key_call =
                (extras[key_call_extra + 3] & ast_mod.CallFlags.optional_chain) != 0;
            if (!isRetainableBoundStaticFieldEffectCall(
                ast,
                semantic,
                property_idx,
                false,
                key_call_mode == .sequence_final or
                    (key_call_mode == .sequence_argument_member_read and optional_key_call),
                switch (key_call_mode) {
                    .sequence_final => .one,
                    .sequence_argument_member_read => .two,
                    else => .none,
                },
                if (key_call_mode == .sequence_argument_member_read and optional_key_call)
                    .sequence_argument_optional_key_call
                else if (key_call_mode == .sequence_argument_member_read)
                    .sequence_argument_member_read_optional_nested_call
                else
                    .disallowed,
            )) return false;
        }
        saw_member = true;
        current_idx = receiver_idx;
    }
    return false;
}

fn isRetainableUnresolvedStaticFieldCallCallee(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    callee_idx: ast_mod.NodeIndex,
) bool {
    return isRetainableUnresolvedStaticFieldIdentifier(ast, semantic, callee_idx);
}

fn isRetainableUnresolvedOptionalStaticFieldCall(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    call_idx: ast_mod.NodeIndex,
) bool {
    if (call_idx.isNone() or @backingInt(call_idx) >= ast.nodes.items.len) return false;
    const call = ast.getNode(call_idx);
    if (call.tag != .call_expression) return false;
    const extra = call.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 4 or
        (ast.extra_data.items[extra + 3] & ast_mod.CallFlags.optional_chain) == 0) return false;
    const callee_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
    return isRetainableUnresolvedStaticFieldCallCallee(ast, semantic, callee_idx);
}

fn isRetainableUnresolvedOptionalStaticFieldMemberInvocation(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    call_idx: ast_mod.NodeIndex,
) bool {
    if (call_idx.isNone() or @backingInt(call_idx) >= ast.nodes.items.len) return false;
    const call = ast.getNode(call_idx);
    if (call.tag != .call_expression) return false;
    const extra = call.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 4 or
        (ast.extra_data.items[extra + 3] & ast_mod.CallFlags.optional_chain) == 0) return false;
    const callee_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
    if (callee_idx.isNone() or @backingInt(callee_idx) >= ast.nodes.items.len) return false;
    const callee = ast.getNode(callee_idx);
    if (callee.tag != .static_member_expression and callee.tag != .computed_member_expression) return false;
    const member_extra = callee.data.extra;
    if (member_extra > ast.extra_data.items.len or ast.extra_data.items.len - member_extra < 3) return false;
    const member_flags = ast.extra_data.items[member_extra + 2];
    if (member_flags == ast_mod.MemberFlags.optional_chain) {
        if (!hasUnresolvedStaticFieldMemberChainRoot(ast, semantic, callee_idx)) return false;
    } else if (member_flags == 0) {
        const receiver_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[member_extra]));
        if (!isRetainableUnresolvedStaticFieldCallCallee(ast, semantic, receiver_idx)) return false;
    } else {
        return false;
    }
    return isRetainableStaticFieldOptionalMemberInvocation(allocator, ast, semantic, callee_idx);
}

/// Static-field call validation admits bound optional-member receiver chains
/// that the general optional-call preflight cannot prove from the call node
/// alone. Keep this allowlist bound-rooted and limited to ordinary calls.
fn isRetainableBoundStaticFieldOptionalMemberCall(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    call_idx: ast_mod.NodeIndex,
) bool {
    if (call_idx.isNone() or @backingInt(call_idx) >= ast.nodes.items.len) return false;
    const call = ast.getNode(call_idx);
    if (call.tag != .call_expression) return false;
    const extra = call.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 4 or
        (ast.extra_data.items[extra + 3] & ast_mod.CallFlags.optional_chain) != 0) return false;
    const callee_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
    return isRetainableStaticFieldOptionalMemberChain(
        allocator,
        ast,
        semantic,
        callee_idx,
        false,
        false,
    );
}

fn isRetainableStaticFieldOptionalMemberCall(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    call_idx: ast_mod.NodeIndex,
) bool {
    if (call_idx.isNone() or @backingInt(call_idx) >= ast.nodes.items.len) return false;
    const call = ast.getNode(call_idx);
    if (call.tag != .call_expression) return false;
    const extra = call.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 4 or
        (ast.extra_data.items[extra + 3] & ast_mod.CallFlags.optional_chain) == 0) return false;
    const callee_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
    return isRetainableStaticFieldOptionalMemberInvocation(allocator, ast, semantic, callee_idx);
}

fn isRetainableStaticFieldDirectOptionalCall(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    callee_idx: ast_mod.NodeIndex,
) bool {
    if (callee_idx.isNone() or @backingInt(callee_idx) >= ast.nodes.items.len or
        ast.getNode(callee_idx).tag != .identifier_reference) return false;
    return isBoundSourceIdentifierReference(ast, semantic, callee_idx) or
        isRetainableUnresolvedStaticFieldCallCallee(ast, semantic, callee_idx);
}

fn isRetainableStaticFieldOptionalMemberInvocation(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    callee_idx: ast_mod.NodeIndex,
) bool {
    if (callee_idx.isNone() or @backingInt(callee_idx) >= ast.nodes.items.len) return false;
    const callee = ast.getNode(callee_idx);
    if (callee.tag != .static_member_expression and callee.tag != .computed_member_expression) return false;
    const extra = callee.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 3) return false;
    const receiver_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
    const member_flags = ast.extra_data.items[extra + 2];
    if (member_flags == ast_mod.MemberFlags.optional_chain) {
        return isRetainableStaticFieldOptionalMemberChain(
            allocator,
            ast,
            semantic,
            callee_idx,
            true,
            true,
        );
    }
    if (member_flags != 0) return false;
    if (receiver_idx.isNone() or @backingInt(receiver_idx) >= ast.nodes.items.len) return false;
    if (ast.getNode(receiver_idx).tag == .identifier_reference and
        (isBoundSourceIdentifierReference(ast, semantic, receiver_idx) or
            isRetainableUnresolvedStaticFieldCallCallee(ast, semantic, receiver_idx)))
    {
        return isRetainableStaticFieldMemberAccess(allocator, ast, semantic, callee_idx);
    }
    if (isRetainableStaticFieldOptionalMemberChain(allocator, ast, semantic, callee_idx, true, true))
        return true;
    return isRetainableStaticFieldCallResultMemberAccess(allocator, ast, semantic, callee_idx);
}

fn isRetainableStaticFieldCallResultMemberAccess(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    member_idx: ast_mod.NodeIndex,
) bool {
    if (member_idx.isNone() or @backingInt(member_idx) >= ast.nodes.items.len) return false;
    const extras = ast.extra_data.items;
    var current_idx = member_idx;
    var saw_member = false;
    var remaining_nodes = ast.nodes.items.len;
    while (remaining_nodes > 0) : (remaining_nodes -= 1) {
        if (current_idx.isNone() or @backingInt(current_idx) >= ast.nodes.items.len) return false;
        const current = ast.getNode(current_idx);
        if (current.tag == .call_expression) {
            if (!saw_member) return false;
            const call_extra = current.data.extra;
            if (call_extra > extras.len or extras.len - call_extra < 4 or
                (extras[call_extra + 3] & ast_mod.CallFlags.optional_chain) != 0) return false;
            const call_callee: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[call_extra]));
            return isRetainableBoundSourceCallCalleeChain(ast, semantic, call_callee) and
                isRetainableStaticFieldCall(allocator, ast, semantic, current_idx, false, false, true);
        }
        if (current.tag != .static_member_expression and current.tag != .computed_member_expression)
            return false;
        const extra = current.data.extra;
        if (extra > extras.len or extras.len - extra < 3 or extras[extra + 2] != 0) return false;
        const receiver_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
        const property_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + 1]));
        if (receiver_idx.isNone() or @backingInt(receiver_idx) >= ast.nodes.items.len or
            property_idx.isNone() or @backingInt(property_idx) >= ast.nodes.items.len) return false;
        if (current.tag == .static_member_expression) {
            if (ast.getNode(property_idx).tag != .identifier_reference) return false;
        } else if (!isSafeConstructorValue(ast, semantic, property_idx) and
            !isUnresolvedSourceIdentifierReference(ast, semantic, property_idx))
        {
            if (ast.getNode(property_idx).tag != .call_expression or
                !isRetainableStaticFieldCall(allocator, ast, semantic, property_idx, false, false, false)) return false;
        }
        saw_member = true;
        current_idx = receiver_idx;
    }
    return false;
}

fn hasUnresolvedStaticFieldMemberChainRoot(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    member_idx: ast_mod.NodeIndex,
) bool {
    const extras = ast.extra_data.items;
    var current_idx = member_idx;
    var remaining_nodes = ast.nodes.items.len;
    while (remaining_nodes > 0) : (remaining_nodes -= 1) {
        if (current_idx.isNone() or @backingInt(current_idx) >= ast.nodes.items.len) return false;
        const current = ast.getNode(current_idx);
        if (current.tag == .identifier_reference)
            return isRetainableUnresolvedStaticFieldCallCallee(ast, semantic, current_idx);
        if (current.tag != .static_member_expression and current.tag != .computed_member_expression)
            return false;
        const extra = current.data.extra;
        if (extra > extras.len or extras.len - extra < 3) return false;
        current_idx = @fromBackingInt(@intCast(extras[extra]));
    }
    return false;
}

fn hasBoundStaticFieldMemberChainRoot(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    member_idx: ast_mod.NodeIndex,
) bool {
    const extras = ast.extra_data.items;
    var current_idx = member_idx;
    var remaining_nodes = ast.nodes.items.len;
    while (remaining_nodes > 0) : (remaining_nodes -= 1) {
        if (current_idx.isNone() or @backingInt(current_idx) >= ast.nodes.items.len) return false;
        const current = ast.getNode(current_idx);
        if (current.tag == .identifier_reference)
            return isBoundSourceIdentifierReference(ast, semantic, current_idx);
        if (current.tag != .static_member_expression and current.tag != .computed_member_expression)
            return false;
        const extra = current.data.extra;
        if (extra > extras.len or extras.len - extra < 3) return false;
        current_idx = @fromBackingInt(@intCast(extras[extra]));
    }
    return false;
}

/// Ordinary calls through an optional-member chain can retain the edited
/// graph when the chain ends at an explicitly unresolved external root. Keep
/// this limited to safe member segments and a non-optional call; the caller's
/// expression validator still checks every argument.
fn isRetainableUnresolvedStaticFieldOptionalMemberCall(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    call_idx: ast_mod.NodeIndex,
) bool {
    if (call_idx.isNone() or @backingInt(call_idx) >= ast.nodes.items.len) return false;
    const call = ast.getNode(call_idx);
    if (call.tag != .call_expression) return false;
    const extra = call.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 4 or
        (ast.extra_data.items[extra + 3] & ast_mod.CallFlags.optional_chain) != 0) return false;
    const callee_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
    return hasUnresolvedStaticFieldMemberChainRoot(ast, semantic, callee_idx) and
        isRetainableStaticFieldOptionalMemberChain(
            allocator,
            ast,
            semantic,
            callee_idx,
            true,
            false,
        );
}

fn collectRetainableStaticFieldOptionalInvocations(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    reachable_nodes: []const u32,
    allowed_nodes: *std.AutoHashMapUnmanaged(u32, void),
) bool {
    for (reachable_nodes) |raw_idx| {
        if (raw_idx >= ast.nodes.items.len) return false;
        const property = ast.nodes.items[raw_idx];
        if (property.tag != .property_definition or
            !isRetainableSimpleStaticClassField(allocator, ast, semantic, property)) continue;
        const extra = property.data.extra;
        if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= ast_mod.PropertyExtra.init)
            return false;
        const init_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra + ast_mod.PropertyExtra.init]));
        if (init_idx.isNone() or @backingInt(init_idx) >= ast.nodes.items.len) return false;
        const initializer_nodes = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, init_idx) catch return false;
        defer ast.allocator.free(initializer_nodes);
        for (initializer_nodes) |call_raw_idx| {
            const call_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(call_raw_idx));
            if (isRetainableBoundStaticFieldOptionalMemberCall(allocator, ast, semantic, call_idx) or
                isRetainableUnresolvedStaticFieldOptionalMemberCall(allocator, ast, semantic, call_idx) or
                isRetainableStaticFieldOptionalMemberCall(allocator, ast, semantic, call_idx))
            {
                allowed_nodes.put(ast.allocator, call_raw_idx, {}) catch return false;
                const call_extra = ast.getNode(call_idx).data.extra;
                var member_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[call_extra]));
                var remaining_nodes = ast.nodes.items.len;
                var reached_root = false;
                while (remaining_nodes > 0) : (remaining_nodes -= 1) {
                    if (member_idx.isNone() or @backingInt(member_idx) >= ast.nodes.items.len) return false;
                    const member = ast.getNode(member_idx);
                    if (member.tag != .static_member_expression and member.tag != .computed_member_expression) {
                        reached_root = true;
                        break;
                    }
                    const member_extra = member.data.extra;
                    if (member_extra > ast.extra_data.items.len or
                        ast.extra_data.items.len - member_extra < 3) return false;
                    if (ast_mod.spineHasOptionalChain(ast, member_idx))
                        allowed_nodes.put(ast.allocator, @backingInt(member_idx), {}) catch return false;
                    member_idx = @fromBackingInt(@intCast(ast.extra_data.items[member_extra]));
                }
                if (!reached_root) return false;
                continue;
            }
            if (!isRetainableUnresolvedOptionalStaticFieldCall(ast, semantic, call_idx) and
                !isRetainableUnresolvedOptionalStaticFieldMemberInvocation(
                    allocator,
                    ast,
                    semantic,
                    call_idx,
                )) continue;
            allowed_nodes.put(ast.allocator, call_raw_idx, {}) catch return false;
        }
    }
    return true;
}

fn isRetainableStaticFieldExpression(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    expression_idx: ast_mod.NodeIndex,
    allow_optional_member_calls: bool,
    allow_optional_invocations: bool,
    allow_nested_call_callees: bool,
) bool {
    if (expression_idx.isNone() or @backingInt(expression_idx) >= ast.nodes.items.len) return false;
    const extras = ast.extra_data.items;
    var pending: std.ArrayList(RetainableStaticFieldExpressionWorkItem) = .empty;
    defer pending.deinit(allocator);
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(allocator);
    pending.append(allocator, .{
        .expression_idx = expression_idx,
        .allow_optional_invocations = allow_optional_invocations,
        .allow_nested_call_callees = allow_nested_call_callees,
    }) catch return false;
    var remaining_nodes = ast.nodes.items.len;

    while (pending.pop()) |work_item| {
        const current_idx = work_item.expression_idx;
        if (remaining_nodes == 0 or current_idx.isNone() or
            @backingInt(current_idx) >= ast.nodes.items.len) return false;
        remaining_nodes -= 1;
        const raw_current = @backingInt(current_idx);
        if (visited.contains(raw_current)) return false;
        visited.put(allocator, raw_current, {}) catch return false;

        if (isSafeConstructorValue(ast, semantic, current_idx)) continue;
        const call = ast.getNode(current_idx);
        switch (call.tag) {
            .call_expression => {
                const extra = call.data.extra;
                if (extra > extras.len or extras.len - extra < 4) return false;
                const optional_call = (extras[extra + 3] & ast_mod.CallFlags.optional_chain) != 0;

                const callee_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
                if (callee_idx.isNone() or @backingInt(callee_idx) >= ast.nodes.items.len) return false;
                const callee = ast.getNode(callee_idx);
                const retained_optional_member_invocation = optional_call and
                    isRetainableStaticFieldOptionalMemberInvocation(
                        allocator,
                        ast,
                        semantic,
                        callee_idx,
                    );
                // Only initializer call trees opt into this extension; computed
                // class keys and standalone member expressions stay on reanalysis.
                const retained_call_result_member_call = !optional_call and
                    work_item.allow_optional_invocations and
                    isRetainableStaticFieldCallResultMemberAccess(
                        allocator,
                        ast,
                        semantic,
                        callee_idx,
                    );
                const retained_call_result_optional_receiver_member_call = !optional_call and
                    work_item.allow_optional_invocations and
                    isRetainableStaticFieldOptionalMemberChain(
                        allocator,
                        ast,
                        semantic,
                        callee_idx,
                        true,
                        true,
                    );
                if (optional_call and (!work_item.allow_optional_invocations or
                    (!isRetainableStaticFieldDirectOptionalCall(ast, semantic, callee_idx) and
                        !retained_optional_member_invocation))) return false;
                switch (callee.tag) {
                    .identifier_reference => {
                        if (!isBoundSourceIdentifierReference(ast, semantic, callee_idx) and
                            !isRetainableUnresolvedStaticFieldCallCallee(ast, semantic, callee_idx)) return false;
                    },
                    .call_expression => {
                        if (!work_item.allow_nested_call_callees or
                            !isRetainableBoundSourceCallCalleeChain(ast, semantic, callee_idx)) return false;
                        pending.append(allocator, .{
                            .expression_idx = callee_idx,
                            .allow_optional_invocations = work_item.allow_optional_invocations,
                            .allow_nested_call_callees = work_item.allow_nested_call_callees,
                        }) catch return false;
                    },
                    .static_member_expression, .computed_member_expression => {
                        if (!retained_optional_member_invocation and !retained_call_result_member_call and
                            !retained_call_result_optional_receiver_member_call and
                            !(allow_optional_member_calls and
                                isRetainableStaticFieldOptionalMemberChain(
                                    allocator,
                                    ast,
                                    semantic,
                                    callee_idx,
                                    true,
                                    false,
                                )) and !enqueueRetainableStaticFieldMemberKeyCalls(
                            allocator,
                            ast,
                            semantic,
                            callee_idx,
                            &pending,
                        )) return false;
                    },
                    else => return false,
                }
                const args_start = extras[extra + 1];
                const args_len = extras[extra + 2];
                if (args_start > extras.len or args_len > extras.len - args_start) return false;
                const allow_optional_member_chain_sequence_arguments = work_item.allow_optional_invocations and
                    isRetainableStaticFieldOptionalMemberChain(
                        allocator,
                        ast,
                        semantic,
                        callee_idx,
                        true,
                        true,
                    );
                for (extras[args_start .. args_start + args_len]) |raw_arg| {
                    if (raw_arg >= ast.nodes.items.len) return false;
                    const argument_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw_arg));
                    if (isSafeConstructorValue(ast, semantic, argument_idx)) continue;
                    const retainable_sequence_argument = allow_optional_member_chain_sequence_arguments and
                        isRetainableBoundStaticFieldSequenceExpression(
                            ast,
                            semantic,
                            argument_idx,
                            false,
                            true,
                            .sequence_argument_member_read,
                            true,
                        );
                    if (retainable_sequence_argument) continue;
                    if (ast.getNode(argument_idx).tag != .call_expression) return false;
                    pending.append(allocator, .{
                        .expression_idx = argument_idx,
                        .allow_optional_invocations = work_item.allow_optional_invocations,
                        .allow_nested_call_callees = work_item.allow_nested_call_callees,
                    }) catch return false;
                }
            },
            .static_member_expression, .computed_member_expression => {
                if (!enqueueRetainableStaticFieldMemberKeyCalls(
                    allocator,
                    ast,
                    semantic,
                    current_idx,
                    &pending,
                )) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn isRetainableStaticFieldMemberAccess(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    member_idx: ast_mod.NodeIndex,
) bool {
    return isRetainableStaticFieldExpression(allocator, ast, semantic, member_idx, false, false, false);
}

fn isRetainableStaticFieldInitializerMemberAccess(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    member_idx: ast_mod.NodeIndex,
) bool {
    return isRetainableStaticFieldOptionalMemberChain(allocator, ast, semantic, member_idx, true, true) or
        isRetainableStaticFieldCallResultMemberAccess(allocator, ast, semantic, member_idx) or
        isRetainableStaticFieldMemberAccess(allocator, ast, semantic, member_idx);
}

fn isRetainableStaticFieldCall(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    call_idx: ast_mod.NodeIndex,
    allow_optional_member_calls: bool,
    allow_optional_invocations: bool,
    allow_nested_call_callees: bool,
) bool {
    if (call_idx.isNone() or @backingInt(call_idx) >= ast.nodes.items.len or
        ast.getNode(call_idx).tag != .call_expression) return false;
    return isRetainableStaticFieldExpression(
        allocator,
        ast,
        semantic,
        call_idx,
        allow_optional_member_calls,
        allow_optional_invocations,
        allow_nested_call_callees,
    );
}

fn isSafeConstructorVarDeclaration(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    declaration: ast_mod.Node,
) bool {
    if (declaration.tag != .variable_declaration) return false;
    const extras = ast.extra_data.items;
    const extra = declaration.data.extra;
    if (extra > extras.len or extras.len - extra < 3 or
        ast.variableDeclarationKind(declaration) != .@"var") return false;
    const declarators_start = extras[extra + 1];
    const declarators_len = extras[extra + 2];
    if (declarators_len == 0 or declarators_start > extras.len or
        declarators_len > extras.len - declarators_start) return false;

    for (extras[declarators_start .. declarators_start + declarators_len]) |raw_declarator_idx| {
        if (raw_declarator_idx >= ast.nodes.items.len) return false;
        const declarator = ast.nodes.items[raw_declarator_idx];
        if (declarator.tag != .variable_declarator) return false;
        const declarator_extra = declarator.data.extra;
        if (declarator_extra > extras.len or extras.len - declarator_extra < 3) return false;
        const binding_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[declarator_extra]));
        const type_annotation_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[declarator_extra + 1]));
        const initializer_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[declarator_extra + 2]));
        if (!type_annotation_idx.isNone() or
            !isBoundSourceIdentifierBinding(ast, semantic, binding_idx) or
            (!initializer_idx.isNone() and !isSafeConstructorValue(ast, semantic, initializer_idx))) return false;
    }
    return true;
}

fn isSafeConstructorForEachHead(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    head_idx: ast_mod.NodeIndex,
) bool {
    if (head_idx.isNone() or @backingInt(head_idx) >= ast.nodes.items.len) return false;
    const head = ast.getNode(head_idx);
    return switch (head.tag) {
        .variable_declaration => switch (ast.variableDeclarationKind(head)) {
            .@"var" => isSafeConstructorVarDeclaration(ast, semantic, head),
            .let, .@"const" => isSafeRetainedLexicalForEachHead(ast, semantic, head),
            else => false,
        },
        .assignment_target_identifier => isBoundSourceIdentifierAssignmentTarget(ast, semantic, head_idx),
        else => false,
    };
}

fn isSafeRetainedLexicalForEachHead(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    declaration: ast_mod.Node,
) bool {
    if (declaration.tag != .variable_declaration) return false;
    const kind = ast.variableDeclarationKind(declaration);
    if (kind != .let and kind != .@"const") return false;

    const extras = ast.extra_data.items;
    const extra = declaration.data.extra;
    if (extra > extras.len or extras.len - extra < 3) return false;
    const declarators_start = extras[extra + 1];
    const declarators_len = extras[extra + 2];
    if (declarators_len != 1 or declarators_start > extras.len or
        declarators_len > extras.len - declarators_start) return false;

    const declarator_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[declarators_start]));
    if (declarator_idx.isNone() or @backingInt(declarator_idx) >= ast.nodes.items.len) return false;
    const declarator = ast.getNode(declarator_idx);
    if (declarator.tag != .variable_declarator) return false;
    const declarator_extra = declarator.data.extra;
    if (declarator_extra > extras.len or extras.len - declarator_extra < 3) return false;
    const binding_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[declarator_extra]));
    const type_annotation_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[declarator_extra + 1]));
    const initializer_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[declarator_extra + 2]));
    if (!type_annotation_idx.isNone() or !initializer_idx.isNone() or
        !isBoundSourceIdentifierBinding(ast, semantic, binding_idx)) return false;

    return kind != .@"const" or hasOnlyReadReferencesToBinding(ast, semantic, binding_idx);
}

fn isSafeConstructorLocalAssignment(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    assignment: ast_mod.Node,
) bool {
    if (assignment.tag != .assignment_expression) return false;
    const operator: token_mod.Kind = @fromBackingInt(@intCast(assignment.data.binary.flags));
    if (operator != .eq and !isSafeConstructorNativeCompoundAssignmentOperator(operator)) return false;
    const target_idx = assignment.data.binary.left;
    if (target_idx.isNone() or @backingInt(target_idx) >= ast.nodes.items.len or
        !isBoundSourceIdentifierAssignmentTarget(ast, semantic, target_idx)) return false;
    return isSafeConstructorValue(ast, semantic, assignment.data.binary.right);
}

fn isSafeConstructorThisPropertyTarget(ast: *const ast_mod.Ast, target_idx: ast_mod.NodeIndex) bool {
    if (target_idx.isNone() or @backingInt(target_idx) >= ast.nodes.items.len) return false;
    const target = ast.getNode(target_idx);
    if (target.tag != .static_member_expression) return false;
    const extras = ast.extra_data.items;
    const member_extra = target.data.extra;
    if (member_extra > extras.len or extras.len - member_extra < 3 or extras[member_extra + 2] != 0)
        return false;

    const receiver_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[member_extra]));
    const property_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[member_extra + 1]));
    if (receiver_idx.isNone() or @backingInt(receiver_idx) >= ast.nodes.items.len or
        ast.getNode(receiver_idx).tag != .this_expression or
        property_idx.isNone() or @backingInt(property_idx) >= ast.nodes.items.len or
        ast.getNode(property_idx).tag != .identifier_reference) return false;
    return std.mem.indexOfScalar(u8, ast.getText(ast.getNode(property_idx).span), '\\') == null;
}

fn isSafeConstructorThisPropertyAssignment(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    assignment: ast_mod.Node,
) bool {
    if (assignment.tag != .assignment_expression) return false;
    const operator: token_mod.Kind = @fromBackingInt(@intCast(assignment.data.binary.flags));
    if (!isSafeConstructorNativeCompoundAssignmentOperator(operator) or
        !isSafeConstructorThisPropertyTarget(ast, assignment.data.binary.left)) return false;
    return isSafeConstructorValue(ast, semantic, assignment.data.binary.right);
}

fn isSafeConstructorThisPropertyUpdate(ast: *const ast_mod.Ast, update: ast_mod.Node) bool {
    if (update.tag != .update_expression) return false;
    const extras = ast.extra_data.items;
    const extra = update.data.extra;
    if (extra > extras.len or extras.len - extra < 2) return false;
    const operator: token_mod.Kind = @fromBackingInt(@intCast(@as(u8, @truncate(extras[extra + 1]))));
    if (operator != .plus2 and operator != .minus2) return false;
    const target_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
    return isSafeConstructorThisPropertyTarget(ast, target_idx);
}

fn isSafeConstructorLocalUpdate(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    update: ast_mod.Node,
) bool {
    if (update.tag != .update_expression) return false;
    const extras = ast.extra_data.items;
    const extra = update.data.extra;
    if (extra > extras.len or extras.len - extra < 2) return false;
    const operator: token_mod.Kind = @fromBackingInt(@intCast(@as(u8, @truncate(extras[extra + 1]))));
    if (operator != .plus2 and operator != .minus2) return false;
    const target_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
    return isBoundSourceIdentifierAssignmentTarget(ast, semantic, target_idx);
}

/// A classic `for` with initialized identifier `let` bindings can keep its source
/// graph when every expression is represented by bound source nodes, no
/// initializer reads a same-or-later header binding, and the body has no
/// generated lexical bindings or nested function capture.
fn hasSelfOrForwardReferenceToLexicalForHeadBinding(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    initializer: ast_mod.NodeIndex,
    declarators: []const u32,
    current_declarator_index: usize,
) bool {
    const descendants = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, initializer) catch return true;
    defer ast.allocator.free(descendants);

    for (descendants) |raw_reference| {
        if (raw_reference >= ast.nodes.items.len or
            ast.nodes.items[raw_reference].tag != .identifier_reference) continue;
        if (raw_reference >= semantic.symbol_ids.len) return true;
        const reference_symbol = semantic.symbol_ids[raw_reference] orelse return true;

        for (declarators[current_declarator_index..]) |raw_declarator| {
            if (raw_declarator >= ast.nodes.items.len) return true;
            const declarator = ast.nodes.items[raw_declarator];
            if (declarator.tag != .variable_declarator) return true;
            const extra = declarator.data.extra;
            if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 1) return true;
            const binding: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
            if (binding.isNone() or @backingInt(binding) >= semantic.symbol_ids.len) return true;
            const binding_symbol = semantic.symbol_ids[@backingInt(binding)] orelse return true;
            if (reference_symbol == binding_symbol) return true;
        }
    }
    return false;
}

fn hasOnlyReadReferencesToBinding(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    binding_idx: ast_mod.NodeIndex,
) bool {
    if (!isBoundSourceIdentifierBinding(ast, semantic, binding_idx)) return false;
    const symbol_raw = semantic.symbol_ids[@backingInt(binding_idx)] orelse return false;
    var declaration_found = false;
    for (semantic.references) |reference| {
        if (@backingInt(reference.symbol_id) != symbol_raw) continue;
        if (reference.flags.declare) {
            if (reference.declaration_node_index == binding_idx) declaration_found = true;
            continue;
        }
        if (reference.flags.write) return false;
    }
    return declaration_found;
}

fn isSafeRetainedLexicalForHead(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    declaration: ast_mod.Node,
) bool {
    if (declaration.tag != .variable_declaration) return false;
    const declaration_kind = ast.variableDeclarationKind(declaration);
    if (declaration_kind != .let and declaration_kind != .@"const") return false;
    const extras = ast.extra_data.items;
    const extra = declaration.data.extra;
    if (extra > extras.len or extras.len - extra < 3) return false;
    const declarators_start = extras[extra + 1];
    const declarators_len = extras[extra + 2];
    if (declarators_len == 0 or declarators_start > extras.len or
        declarators_len > extras.len - declarators_start) return false;

    const declarators = extras[declarators_start .. declarators_start + declarators_len];
    for (declarators, 0..) |raw_declarator, declarator_index| {
        if (raw_declarator >= ast.nodes.items.len) return false;
        const declarator = ast.nodes.items[raw_declarator];
        if (declarator.tag != .variable_declarator) return false;
        const declarator_extra = declarator.data.extra;
        if (declarator_extra > extras.len or extras.len - declarator_extra < 3) return false;
        const binding: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[declarator_extra]));
        const type_annotation: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[declarator_extra + 1]));
        const initializer: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[declarator_extra + 2]));
        if (!type_annotation.isNone() or
            !isBoundSourceIdentifierBinding(ast, semantic, binding) or
            (declaration_kind == .@"const" and
                !hasOnlyReadReferencesToBinding(ast, semantic, binding)) or
            initializer.isNone() or
            !isSafeConstructorValue(ast, semantic, initializer) or
            hasSelfOrForwardReferenceToLexicalForHeadBinding(
                ast,
                semantic,
                initializer,
                declarators,
                declarator_index,
            )) return false;
    }
    return true;
}

fn isSafeConstructorExpression(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    expression_idx: ast_mod.NodeIndex,
) bool {
    if (expression_idx.isNone() or @backingInt(expression_idx) >= ast.nodes.items.len) return false;
    const assignment = ast.getNode(expression_idx);
    if (assignment.tag == .update_expression) {
        return isSafeConstructorLocalUpdate(ast, semantic, assignment) or
            isSafeConstructorThisPropertyUpdate(ast, assignment);
    }
    if (assignment.tag != .assignment_expression) return false;
    if (assignment.data.binary.flags != @backingInt(token_mod.Kind.eq)) {
        return isSafeConstructorLocalAssignment(ast, semantic, assignment) or
            isSafeConstructorThisPropertyAssignment(ast, semantic, assignment);
    }

    const target_idx = assignment.data.binary.left;
    const value_idx = assignment.data.binary.right;
    if (target_idx.isNone() or @backingInt(target_idx) >= ast.nodes.items.len or
        value_idx.isNone() or @backingInt(value_idx) >= ast.nodes.items.len) return false;
    if (ast.getNode(target_idx).tag == .static_member_expression) {
        return isSafeConstructorThisPropertyTarget(ast, target_idx) and
            isSafeConstructorValue(ast, semantic, value_idx);
    }
    return isSafeConstructorLocalAssignment(ast, semantic, assignment);
}

fn isSafeConstructorExpressionStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement: ast_mod.Node,
) bool {
    return statement.tag == .expression_statement and
        isSafeConstructorExpression(ast, semantic, statement.data.unary.operand);
}

fn isSafeConstructorSwitchCase(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    case_idx: ast_mod.NodeIndex,
) bool {
    if (case_idx.isNone() or @backingInt(case_idx) >= ast.nodes.items.len) return false;
    const switch_case = ast.getNode(case_idx);
    if (switch_case.tag != .switch_case) return false;
    const extras = ast.extra_data.items;
    const extra = switch_case.data.extra;
    if (extra > extras.len or extras.len - extra < 3) return false;
    const test_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
    const statements_start = extras[extra + 1];
    const statements_len = extras[extra + 2];
    if ((!test_idx.isNone() and !isSafeConstructorValue(ast, semantic, test_idx)) or
        statements_start > extras.len or statements_len > extras.len - statements_start) return false;
    for (extras[statements_start .. statements_start + statements_len]) |raw_statement_idx| {
        if (raw_statement_idx >= ast.nodes.items.len or
            !isSafeConstructorBodyStatement(ast, semantic, @fromBackingInt(@intCast(raw_statement_idx)))) return false;
    }
    return true;
}

fn isSafeRetainedLexicalForStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement: ast_mod.Node,
) bool {
    if (statement.tag != .for_statement) return false;
    const extras = ast.extra_data.items;
    const extra = statement.data.extra;
    if (extra > extras.len or extras.len - extra < 4) return false;
    const initializer_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
    const test_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + 1]));
    const update_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + 2]));
    const body_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + 3]));
    if (initializer_idx.isNone() or @backingInt(initializer_idx) >= ast.nodes.items.len or
        ast.getNode(initializer_idx).tag != .variable_declaration or
        !isSafeRetainedLexicalForHead(ast, semantic, ast.getNode(initializer_idx))) return false;
    return (test_idx.isNone() or isSafeConstructorValue(ast, semantic, test_idx)) and
        (update_idx.isNone() or isSafeConstructorExpression(ast, semantic, update_idx)) and
        isSafeConstructorBodyStatement(ast, semantic, body_idx);
}

fn isSafeConstructorCatchClause(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    catch_idx: ast_mod.NodeIndex,
) bool {
    if (catch_idx.isNone() or @backingInt(catch_idx) >= ast.nodes.items.len) return false;
    const catch_clause = ast.getNode(catch_idx);
    if (catch_clause.tag != .catch_clause) return false;
    const parameter_idx = catch_clause.data.binary.left;
    if (!parameter_idx.isNone() and !isBoundSourceIdentifierBinding(ast, semantic, parameter_idx)) return false;
    const body_idx = catch_clause.data.binary.right;
    return !body_idx.isNone() and @backingInt(body_idx) < ast.nodes.items.len and
        ast.getNode(body_idx).tag == .block_statement and
        isSafeConstructorBodyStatement(ast, semantic, body_idx);
}

fn isSafeConstructorLabelIdentifier(ast: *const ast_mod.Ast, label_idx: ast_mod.NodeIndex) bool {
    if (label_idx.isNone() or @backingInt(label_idx) >= ast.nodes.items.len) return false;
    const label = ast.getNode(label_idx);
    return label.tag == .identifier_reference and
        std.mem.indexOfScalar(u8, ast.getText(label.span), '\\') == null;
}

fn isSafeConstructorBodyStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement_idx: ast_mod.NodeIndex,
) bool {
    if (statement_idx.isNone() or @backingInt(statement_idx) >= ast.nodes.items.len) return false;
    const statement = ast.getNode(statement_idx);
    switch (statement.tag) {
        .empty_statement => return true,
        .debugger_statement => return true,
        .break_statement, .continue_statement => {
            const label_idx = statement.data.unary.operand;
            return label_idx.isNone() or isSafeConstructorLabelIdentifier(ast, label_idx);
        },
        .return_statement => {
            const value_idx = statement.data.unary.operand;
            return value_idx.isNone() or isSafeConstructorValue(ast, semantic, value_idx);
        },
        .throw_statement => return isSafeConstructorValue(ast, semantic, statement.data.unary.operand),
        .variable_declaration => return isSafeConstructorVarDeclaration(ast, semantic, statement),
        .expression_statement => return isSafeConstructorExpressionStatement(ast, semantic, statement),
        .block_statement => {
            const statements = statement.data.list;
            const extras = ast.extra_data.items;
            if (statements.start > extras.len or statements.len > extras.len - statements.start) return false;
            for (extras[statements.start .. statements.start + statements.len]) |raw_statement_idx| {
                if (raw_statement_idx >= ast.nodes.items.len or
                    !isSafeConstructorBodyStatement(ast, semantic, @fromBackingInt(@intCast(raw_statement_idx)))) return false;
            }
            return true;
        },
        .if_statement => {
            const branches = statement.data.ternary;
            return isSafeConstructorValue(ast, semantic, branches.a) and
                isSafeConstructorBodyStatement(ast, semantic, branches.b) and
                (branches.c.isNone() or isSafeConstructorBodyStatement(ast, semantic, branches.c));
        },
        .labeled_statement => {
            const label = statement.data.binary.left;
            return isSafeConstructorLabelIdentifier(ast, label) and
                isSafeConstructorBodyStatement(ast, semantic, statement.data.binary.right);
        },
        .switch_statement => {
            const extras = ast.extra_data.items;
            const extra = statement.data.extra;
            if (extra > extras.len or extras.len - extra < 3) return false;
            const discriminant_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
            const cases_start = extras[extra + 1];
            const cases_len = extras[extra + 2];
            if (!isSafeConstructorValue(ast, semantic, discriminant_idx) or
                cases_start > extras.len or cases_len > extras.len - cases_start) return false;
            for (extras[cases_start .. cases_start + cases_len]) |raw_case_idx| {
                if (raw_case_idx >= ast.nodes.items.len or
                    !isSafeConstructorSwitchCase(ast, semantic, @fromBackingInt(@intCast(raw_case_idx)))) return false;
            }
            return true;
        },
        .try_statement => {
            const clauses = statement.data.ternary;
            if ((clauses.b.isNone() and clauses.c.isNone()) or clauses.a.isNone() or
                @backingInt(clauses.a) >= ast.nodes.items.len or
                ast.getNode(clauses.a).tag != .block_statement) return false;
            if (!clauses.c.isNone() and
                (@backingInt(clauses.c) >= ast.nodes.items.len or ast.getNode(clauses.c).tag != .block_statement))
            {
                return false;
            }
            return isSafeConstructorBodyStatement(ast, semantic, clauses.a) and
                (clauses.b.isNone() or isSafeConstructorCatchClause(ast, semantic, clauses.b)) and
                (clauses.c.isNone() or isSafeConstructorBodyStatement(ast, semantic, clauses.c));
        },
        .for_statement => {
            const extras = ast.extra_data.items;
            const extra = statement.data.extra;
            if (extra > extras.len or extras.len - extra < 4) return false;
            const initializer_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
            const test_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + 1]));
            const update_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + 2]));
            const body_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + 3]));
            if (!initializer_idx.isNone() and @backingInt(initializer_idx) < ast.nodes.items.len and
                ast.getNode(initializer_idx).tag == .variable_declaration and
                ast.variableDeclarationKind(ast.getNode(initializer_idx)).isLexical())
            {
                return isSafeRetainedLexicalForStatement(ast, semantic, statement);
            }
            const safe_initializer = initializer_idx.isNone() or
                (if (@backingInt(initializer_idx) < ast.nodes.items.len and
                    ast.getNode(initializer_idx).tag == .variable_declaration)
                    isSafeConstructorVarDeclaration(ast, semantic, ast.getNode(initializer_idx))
                else
                    isSafeConstructorExpression(ast, semantic, initializer_idx));
            return safe_initializer and
                (test_idx.isNone() or isSafeConstructorValue(ast, semantic, test_idx)) and
                (update_idx.isNone() or isSafeConstructorExpression(ast, semantic, update_idx)) and
                isSafeConstructorBodyStatement(ast, semantic, body_idx);
        },
        .while_statement, .do_while_statement => {
            const loop = statement.data.binary;
            return isSafeConstructorValue(ast, semantic, loop.left) and
                isSafeConstructorBodyStatement(ast, semantic, loop.right);
        },
        .for_in_statement, .for_of_statement => {
            const loop = statement.data.ternary;
            return isSafeConstructorForEachHead(ast, semantic, loop.a) and
                isSafeConstructorValue(ast, semantic, loop.b) and
                isSafeConstructorBodyStatement(ast, semantic, loop.c);
        },
        else => return false,
    }
}

fn isEarlierConstructorParameterReference(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    reference_idx: ast_mod.NodeIndex,
    params: ast_mod.NodeList,
    parameter_index: u32,
) bool {
    if (!hasValidSourceSymbol(ast, semantic, reference_idx, .identifier_reference) or
        parameter_index > params.len or params.start > ast.extra_data.items.len or
        params.len > ast.extra_data.items.len - params.start) return false;
    const reference_symbol = semantic.symbol_ids[@backingInt(reference_idx)] orelse return false;
    for (ast.extra_data.items[params.start .. params.start + parameter_index]) |raw_parameter_idx| {
        if (raw_parameter_idx >= ast.nodes.items.len) return false;
        const parameter_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw_parameter_idx));
        const parameter = ast.getNode(parameter_idx);
        const binding_idx = switch (parameter.tag) {
            .binding_identifier => parameter_idx,
            .assignment_pattern => parameter.data.binary.left,
            else => return false,
        };
        if (!hasValidSourceSymbol(ast, semantic, binding_idx, .binding_identifier)) return false;
        if (semantic.symbol_ids[@backingInt(binding_idx)] == reference_symbol) return true;
    }
    return false;
}

fn isSafeConstructorParameterDefaultValue(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    value_idx: ast_mod.NodeIndex,
    params: ast_mod.NodeList,
    parameter_index: u32,
) bool {
    if (value_idx.isNone() or @backingInt(value_idx) >= ast.nodes.items.len) return false;
    const value = ast.getNode(value_idx);
    if (value.tag == .binary_expression) {
        const operator: token_mod.Kind = @fromBackingInt(@intCast(value.data.binary.flags));
        return isSafeConstructorBinaryOperator(operator) and
            isSafeConstructorParameterDefaultValue(ast, semantic, value.data.binary.left, params, parameter_index) and
            isSafeConstructorParameterDefaultValue(ast, semantic, value.data.binary.right, params, parameter_index);
    }
    if (value.tag == .unary_expression) {
        const extras = ast.extra_data.items;
        const extra = value.data.extra;
        if (extra > extras.len or extras.len - extra < 2) return false;
        const operator: token_mod.Kind = @fromBackingInt(@intCast(@as(u8, @truncate(extras[extra + 1]))));
        const operand_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
        return isSafeConstructorUnaryOperator(operator) and
            isSafeConstructorParameterDefaultValue(ast, semantic, operand_idx, params, parameter_index);
    }
    if (value.tag == .logical_expression) {
        const operator: token_mod.Kind = @fromBackingInt(@intCast(value.data.binary.flags));
        return isSafeConstructorLogicalOperator(operator) and
            isSafeConstructorParameterDefaultValue(ast, semantic, value.data.binary.left, params, parameter_index) and
            isSafeConstructorParameterDefaultValue(ast, semantic, value.data.binary.right, params, parameter_index);
    }
    if (value.tag == .conditional_expression) {
        return isSafeConstructorParameterDefaultValue(ast, semantic, value.data.ternary.a, params, parameter_index) and
            isSafeConstructorParameterDefaultValue(ast, semantic, value.data.ternary.b, params, parameter_index) and
            isSafeConstructorParameterDefaultValue(ast, semantic, value.data.ternary.c, params, parameter_index);
    }
    return switch (value.tag) {
        .boolean_literal, .null_literal, .numeric_literal, .string_literal => true,
        .identifier_reference => isEarlierConstructorParameterReference(
            ast,
            semantic,
            value_idx,
            params,
            parameter_index,
        ),
        else => false,
    };
}

fn isSimpleConstructorParameterGraphSafe(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    parameter_idx: ast_mod.NodeIndex,
    params: ast_mod.NodeList,
    parameter_index: u32,
) bool {
    if (parameter_idx.isNone() or @backingInt(parameter_idx) >= ast.nodes.items.len) return false;
    const parameter = ast.getNode(parameter_idx);
    if (parameter.tag == .binding_identifier)
        return isBoundSourceIdentifierBinding(ast, semantic, parameter_idx);
    if (parameter.tag != .assignment_pattern) return false;

    // Defaults can read an earlier simple parameter because lowering evaluates
    // them in order and TDZ rewriting only targets this and later parameters.
    // Admit those references by exact SymbolId; spelling alone is insufficient.
    const binding_idx = parameter.data.binary.left;
    const default_idx = parameter.data.binary.right;
    if (!isBoundSourceIdentifierBinding(ast, semantic, binding_idx) or
        default_idx.isNone() or @backingInt(default_idx) >= ast.nodes.items.len) return false;
    return isSafeConstructorParameterDefaultValue(ast, semantic, default_idx, params, parameter_index);
}

/// The retained explicit derived-constructor case is intentionally narrow:
/// simple identifier parameters with audited defaults, a leading `super(...)`
/// whose arguments use the constructor value allowlist, then only audited
/// post-super statements. Lowering this shape adds tracked `_this`/`_newTarget`
/// captures and derived-constructor runtime helpers. Call, member-access, and
/// spread arguments, plus unsupported post-super statements, remain on
/// semantic reanalysis.
fn isSafeSuperConstructorStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement_idx: ast_mod.NodeIndex,
) bool {
    if (statement_idx.isNone() or @backingInt(statement_idx) >= ast.nodes.items.len) return false;
    const statement = ast.getNode(statement_idx);
    if (statement.tag != .expression_statement) return false;
    const expression_idx = statement.data.unary.operand;
    if (expression_idx.isNone() or @backingInt(expression_idx) >= ast.nodes.items.len) return false;
    const call = ast.getNode(expression_idx);
    if (call.tag != .call_expression) return false;
    const extras = ast.extra_data.items;
    const extra = call.data.extra;
    if (extra > extras.len or extras.len - extra < 4 or extras[extra + 3] != 0) return false;
    const callee_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
    if (callee_idx.isNone() or @backingInt(callee_idx) >= ast.nodes.items.len or
        ast.getNode(callee_idx).tag != .super_expression) return false;
    const args_start = extras[extra + 1];
    const args_len = extras[extra + 2];
    if (args_start > extras.len or args_len > extras.len - args_start) return false;
    for (extras[args_start .. args_start + args_len]) |raw_argument_idx| {
        if (raw_argument_idx >= ast.nodes.items.len or
            !isSafeConstructorValue(ast, semantic, @fromBackingInt(@intCast(raw_argument_idx)))) return false;
    }
    return true;
}

fn isSafeConstructorThisPropertyAssignmentStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement_idx: ast_mod.NodeIndex,
) bool {
    if (statement_idx.isNone() or @backingInt(statement_idx) >= ast.nodes.items.len) return false;
    const statement = ast.getNode(statement_idx);
    if (statement.tag != .expression_statement) return false;
    const expression_idx = statement.data.unary.operand;
    if (expression_idx.isNone() or @backingInt(expression_idx) >= ast.nodes.items.len) return false;
    const assignment = ast.getNode(expression_idx);
    if (assignment.tag != .assignment_expression or
        assignment.data.binary.flags != @backingInt(token_mod.Kind.eq) or
        !isSafeConstructorThisPropertyTarget(ast, assignment.data.binary.left)) return false;
    return isSafeConstructorValue(ast, semantic, assignment.data.binary.right);
}

fn isSafePostSuperDerivedConstructorReturnStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement_idx: ast_mod.NodeIndex,
) bool {
    if (statement_idx.isNone() or @backingInt(statement_idx) >= ast.nodes.items.len) return false;
    const statement = ast.getNode(statement_idx);
    if (statement.tag != .return_statement) return false;
    const value_idx = statement.data.unary.operand;
    return value_idx.isNone() or isSafePostSuperInitializerValue(ast, semantic, value_idx);
}

fn isSafePostSuperDerivedConstructorThrowStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement_idx: ast_mod.NodeIndex,
) bool {
    if (statement_idx.isNone() or @backingInt(statement_idx) >= ast.nodes.items.len) return false;
    const statement = ast.getNode(statement_idx);
    if (statement.tag != .throw_statement) return false;
    const value_idx = statement.data.unary.operand;
    return !value_idx.isNone() and @backingInt(value_idx) < ast.nodes.items.len and
        isSafePostSuperInitializerValue(ast, semantic, value_idx);
}

fn isSafePostSuperConditionalBranch(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    branch_idx: ast_mod.NodeIndex,
) bool {
    if (branch_idx.isNone() or @backingInt(branch_idx) >= ast.nodes.items.len) return false;
    const statement = ast.getNode(branch_idx);
    if (statement.tag == .block_statement) {
        const statements = statement.data.list;
        const extras = ast.extra_data.items;
        if (statements.start > extras.len or statements.len > extras.len - statements.start) return false;
        for (extras[statements.start .. statements.start + statements.len], 0..) |raw_statement_idx, index| {
            if (raw_statement_idx >= ast.nodes.items.len) return false;
            if (index + 1 == statements.len) {
                const final_statement: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw_statement_idx));
                if (isSafePostSuperDerivedConstructorReturnStatement(ast, semantic, final_statement) or
                    isSafePostSuperDerivedConstructorThrowStatement(ast, semantic, final_statement)) return true;
            }
            const nested_statement = ast.getNode(@fromBackingInt(@intCast(raw_statement_idx)));
            if (nested_statement.tag == .empty_statement or nested_statement.tag == .debugger_statement) continue;
            // Strict block functions bind to this branch block. Their bodies
            // are deferred and remain covered by the graph and identity gates.
            if (nested_statement.tag == .function_declaration) continue;
            if (isSafeConstructorVarDeclaration(ast, semantic, nested_statement) or
                isSafePostSuperExpressionStatement(ast, semantic, @fromBackingInt(@intCast(raw_statement_idx)))) continue;
            if (isSafePostSuperNonCompletingBlockOrLabelStatement(
                ast,
                semantic,
                @fromBackingInt(@intCast(raw_statement_idx)),
            )) continue;
            if (isSafePostSuperConditionalStatement(ast, semantic, @fromBackingInt(@intCast(raw_statement_idx)))) continue;
            if (isSafePostSuperLoopStatement(ast, semantic, @fromBackingInt(@intCast(raw_statement_idx)))) continue;
            if (isSafePostSuperSwitchStatement(ast, semantic, @fromBackingInt(@intCast(raw_statement_idx)))) continue;
            if (isSafePostSuperTryStatement(ast, semantic, @fromBackingInt(@intCast(raw_statement_idx)))) continue;
            return false;
        }
        return true;
    }
    if (statement.tag == .return_statement)
        return isSafePostSuperDerivedConstructorReturnStatement(ast, semantic, branch_idx);
    if (statement.tag == .throw_statement)
        return isSafePostSuperDerivedConstructorThrowStatement(ast, semantic, branch_idx);
    return isSafeConstructorThisPropertyAssignmentStatement(ast, semantic, branch_idx);
}

fn isSafePostSuperCondition(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    condition_idx: ast_mod.NodeIndex,
) bool {
    // Reads may invoke getters or Proxy traps. The retained AST preserves each
    // operand's evaluation count and short-circuit order through initialized this.
    if (isSafeConstructorValue(ast, semantic, condition_idx) or
        isSafePostSuperThisPropertyRead(ast, semantic, condition_idx) or
        isSafePostSuperPropertyRead(ast, semantic, condition_idx)) return true;
    if (condition_idx.isNone() or @backingInt(condition_idx) >= ast.nodes.items.len) return false;
    const condition = ast.getNode(condition_idx);
    if (condition.tag == .binary_expression) {
        const operator: token_mod.Kind = @fromBackingInt(@intCast(condition.data.binary.flags));
        return isSafeConstructorBinaryOperator(operator) and
            isSafePostSuperCondition(ast, semantic, condition.data.binary.left) and
            isSafePostSuperCondition(ast, semantic, condition.data.binary.right);
    }
    if (condition.tag == .logical_expression) {
        const operator: token_mod.Kind = @fromBackingInt(@intCast(condition.data.binary.flags));
        return isSafeConstructorLogicalOperator(operator) and
            isSafePostSuperCondition(ast, semantic, condition.data.binary.left) and
            isSafePostSuperCondition(ast, semantic, condition.data.binary.right);
    }
    if (condition.tag == .unary_expression) {
        const extras = ast.extra_data.items;
        const extra = condition.data.extra;
        if (extra > extras.len or extras.len - extra < 2) return false;
        const operator: token_mod.Kind = @fromBackingInt(@intCast(@as(u8, @truncate(extras[extra + 1]))));
        const operand_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
        return isSafeConstructorUnaryOperator(operator) and
            isSafePostSuperCondition(ast, semantic, operand_idx);
    }
    if (condition.tag == .conditional_expression) {
        return isSafePostSuperCondition(ast, semantic, condition.data.ternary.a) and
            isSafePostSuperCondition(ast, semantic, condition.data.ternary.b) and
            isSafePostSuperCondition(ast, semantic, condition.data.ternary.c);
    }
    return false;
}

fn isSafePostSuperCallExpression(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    call_idx: ast_mod.NodeIndex,
    allow_this_receiver: bool,
) bool {
    if (call_idx.isNone() or @backingInt(call_idx) >= ast.nodes.items.len) return false;
    const call = ast.getNode(call_idx);
    if (call.tag != .call_expression) return false;
    const extras = ast.extra_data.items;
    const extra = call.data.extra;
    if (extra > extras.len or extras.len - extra < 4 or extras[extra + 3] != 0) return false;
    const callee_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
    if (callee_idx.isNone() or @backingInt(callee_idx) >= ast.nodes.items.len) return false;
    const callee = ast.getNode(callee_idx);
    if (callee.tag == .identifier_reference) {
        const name = ast.getText(callee.span);
        if (std.mem.eql(u8, name, "eval") or std.mem.indexOfScalar(u8, name, '\\') != null or
            !isBoundSourceIdentifierReference(ast, semantic, callee_idx)) return false;
    } else if (!allow_this_receiver or !isSafeConstructorThisPropertyTarget(ast, callee_idx)) return false;

    const args_start = extras[extra + 1];
    const args_len = extras[extra + 2];
    if (args_start > extras.len or args_len > extras.len - args_start) return false;
    for (extras[args_start .. args_start + args_len]) |raw_arg_idx| {
        if (raw_arg_idx >= ast.nodes.items.len or
            !isSafeConstructorValue(ast, semantic, @fromBackingInt(@intCast(raw_arg_idx)))) return false;
    }
    return true;
}

fn isSafePostSuperExpressionStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement_idx: ast_mod.NodeIndex,
) bool {
    if (statement_idx.isNone() or @backingInt(statement_idx) >= ast.nodes.items.len) return false;
    const statement = ast.getNode(statement_idx);
    if (statement.tag != .expression_statement) return false;
    const expression_idx = statement.data.unary.operand;
    return isSafeConstructorExpressionStatement(ast, semantic, statement) or
        isSafePostSuperCallExpression(ast, semantic, expression_idx, true) or
        isSafePostSuperPropertyAssignment(ast, semantic, expression_idx) or
        isSafePostSuperInitializerValue(ast, semantic, expression_idx);
}

/// A bare direct `super` property read after initialization can retain its
/// exact home-object reference. Keep computed keys to source-bound values so
/// their single evaluation stays easy to audit.
fn isSafePostSuperPropertyRead(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    expression_idx: ast_mod.NodeIndex,
) bool {
    if (!isRetainableDirectSuperPropertyAccess(ast, expression_idx, false)) return false;
    const member = ast.getNode(expression_idx);
    if (member.tag == .computed_member_expression) {
        const property_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[member.data.extra + 1]));
        return isSafeConstructorValue(ast, semantic, property_idx);
    }
    return true;
}

fn isSafePostSuperThisPropertyRead(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    expression_idx: ast_mod.NodeIndex,
) bool {
    if (isSafeConstructorThisPropertyTarget(ast, expression_idx)) return true;
    if (expression_idx.isNone() or @backingInt(expression_idx) >= ast.nodes.items.len or
        ast_mod.spineHasOptionalChain(ast, expression_idx)) return false;
    const member = ast.getNode(expression_idx);
    if (member.tag != .computed_member_expression) return false;
    const extras = ast.extra_data.items;
    const extra = member.data.extra;
    if (extra > extras.len or extras.len - extra < 3) return false;
    const receiver_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
    const property_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + 1]));
    return !receiver_idx.isNone() and @backingInt(receiver_idx) < ast.nodes.items.len and
        ast.getNode(receiver_idx).tag == .this_expression and
        isSafeConstructorValue(ast, semantic, property_idx);
}

/// A source-bound initializer may combine direct `super` and static `this`
/// property reads with the same bounded unary, binary, and logical operators
/// already allowed for ordinary constructor values. Conditional tests use the
/// audited post-super condition allowlist, while their branches use this value
/// set; calls and member chains keep their separate reanalysis boundary.
fn isSafePostSuperInitializerValue(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    value_idx: ast_mod.NodeIndex,
) bool {
    if (isSafeConstructorValue(ast, semantic, value_idx) or
        isSafePostSuperThisPropertyRead(ast, semantic, value_idx) or
        isSafePostSuperPropertyRead(ast, semantic, value_idx)) return true;
    if (value_idx.isNone() or @backingInt(value_idx) >= ast.nodes.items.len) return false;
    const value = ast.getNode(value_idx);
    if (value.tag == .logical_expression) {
        const operator: token_mod.Kind = @fromBackingInt(@intCast(value.data.binary.flags));
        return isSafeConstructorLogicalOperator(operator) and
            isSafePostSuperInitializerValue(ast, semantic, value.data.binary.left) and
            isSafePostSuperInitializerValue(ast, semantic, value.data.binary.right);
    }
    if (value.tag == .unary_expression) {
        const extras = ast.extra_data.items;
        const extra = value.data.extra;
        if (extra > extras.len or extras.len - extra < 2) return false;
        const operator: token_mod.Kind = @fromBackingInt(@intCast(@as(u8, @truncate(extras[extra + 1]))));
        const operand_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
        return isSafeConstructorUnaryOperator(operator) and
            isSafePostSuperInitializerValue(ast, semantic, operand_idx);
    }
    if (value.tag == .conditional_expression) {
        return isSafePostSuperCondition(ast, semantic, value.data.ternary.a) and
            isSafePostSuperInitializerValue(ast, semantic, value.data.ternary.b) and
            isSafePostSuperInitializerValue(ast, semantic, value.data.ternary.c);
    }
    if (value.tag != .binary_expression) return false;
    const operator: token_mod.Kind = @fromBackingInt(@intCast(value.data.binary.flags));
    return isSafeConstructorBinaryOperator(operator) and
        isSafePostSuperInitializerValue(ast, semantic, value.data.binary.left) and
        isSafePostSuperInitializerValue(ast, semantic, value.data.binary.right);
}

/// A single simple `var` initializer may read one direct `super` property
/// or a bounded binary expression containing those reads after the derived
/// receiver has been initialized. Keep compound declarations and lexical
/// bindings on reanalysis so their scope edits remain independently audited.
fn isSafePostSuperVarDeclaration(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    declaration: ast_mod.Node,
) bool {
    if (isSafeConstructorVarDeclaration(ast, semantic, declaration)) return true;
    if (declaration.tag != .variable_declaration or
        ast.variableDeclarationKind(declaration) != .@"var") return false;

    const extras = ast.extra_data.items;
    const extra = declaration.data.extra;
    if (extra > extras.len or extras.len - extra < 3) return false;
    const declarators_start = extras[extra + 1];
    const declarators_len = extras[extra + 2];
    if (declarators_len != 1 or declarators_start >= extras.len or
        extras[declarators_start] >= ast.nodes.items.len) return false;

    const declarator = ast.nodes.items[extras[declarators_start]];
    if (declarator.tag != .variable_declarator) return false;
    const declarator_extra = declarator.data.extra;
    if (declarator_extra > extras.len or extras.len - declarator_extra < 3) return false;
    const binding_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[declarator_extra]));
    const type_annotation_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[declarator_extra + 1]));
    const initializer_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[declarator_extra + 2]));
    return type_annotation_idx.isNone() and
        isBoundSourceIdentifierBinding(ast, semantic, binding_idx) and
        isSafePostSuperInitializerValue(ast, semantic, initializer_idx);
}

/// A derived constructor can use an exact direct `super` property assignment
/// after its first `super()` call. Keep this proof separate from the general
/// constructor expression allowlist: before `super()` the receiver is still
/// uninitialized, and nested scopes or effectful keys need their own graph
/// proof. The transform registers the generated home-object reads and temps.
fn isSafePostSuperPropertyAssignment(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    expression_idx: ast_mod.NodeIndex,
) bool {
    if (expression_idx.isNone() or @backingInt(expression_idx) >= ast.nodes.items.len) return false;
    const assignment = ast.getNode(expression_idx);
    if (assignment.tag != .assignment_expression) return false;
    const operator: token_mod.Kind = @fromBackingInt(@intCast(assignment.data.binary.flags));
    switch (operator) {
        .eq, .question2_eq, .pipe2_eq, .amp2_eq, .star2_eq => {},
        else => return false,
    }

    const target_idx = assignment.data.binary.left;
    const value_idx = assignment.data.binary.right;
    if (!isRetainableDirectSuperPropertyAccess(ast, target_idx, false) or
        !isSafeConstructorValue(ast, semantic, value_idx)) return false;

    const target = ast.getNode(target_idx);
    if (target.tag == .computed_member_expression) {
        const property_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[target.data.extra + 1]));
        if (!isSafeConstructorValue(ast, semantic, property_idx)) return false;
    }
    return true;
}

fn isSafePostSuperSwitchExpressionStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement_idx: ast_mod.NodeIndex,
) bool {
    if (statement_idx.isNone() or @backingInt(statement_idx) >= ast.nodes.items.len) return false;
    const statement = ast.getNode(statement_idx);
    if (statement.tag != .expression_statement) return false;
    const expression_idx = statement.data.unary.operand;
    if (isSafePostSuperCallExpression(ast, semantic, expression_idx, false)) return true;
    if (expression_idx.isNone() or @backingInt(expression_idx) >= ast.nodes.items.len) return false;
    const expression = ast.getNode(expression_idx);
    if (expression.tag == .update_expression)
        return isSafeConstructorLocalUpdate(ast, semantic, expression);
    if (expression.tag == .assignment_expression)
        return isSafeConstructorLocalAssignment(ast, semantic, expression);
    return false;
}

fn isSafePostSuperConditionalStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement_idx: ast_mod.NodeIndex,
) bool {
    if (statement_idx.isNone() or @backingInt(statement_idx) >= ast.nodes.items.len or
        ast.getNode(statement_idx).tag != .if_statement) return false;

    // An `else if` is represented as an if statement in the prior if's
    // alternative. Walk that chain iteratively so source depth cannot grow
    // this safety check's call stack.
    var current_idx = statement_idx;
    var remaining_nodes = ast.nodes.items.len;
    while (remaining_nodes > 0) : (remaining_nodes -= 1) {
        if (current_idx.isNone() or @backingInt(current_idx) >= ast.nodes.items.len) return false;
        const statement = ast.getNode(current_idx);
        if (statement.tag != .if_statement) return false;
        const branches = statement.data.ternary;
        if (!isSafePostSuperCondition(ast, semantic, branches.a) or
            !isSafePostSuperConditionalBranch(ast, semantic, branches.b)) return false;

        if (branches.c.isNone()) return true;
        if (@backingInt(branches.c) >= ast.nodes.items.len) return false;
        if (ast.getNode(branches.c).tag == .if_statement) {
            current_idx = branches.c;
            continue;
        }
        return isSafePostSuperConditionalBranch(ast, semantic, branches.c);
    }
    return false;
}

fn isSafeStrictSwitchBlockFunctionDeclaration(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    declaration_idx: ast_mod.NodeIndex,
) bool {
    if (declaration_idx.isNone() or @backingInt(declaration_idx) >= ast.nodes.items.len) return false;
    const declaration = ast.getNode(declaration_idx);
    if (declaration.tag != .function_declaration) return false;

    const extra = declaration.data.extra;
    const extras = ast.extra_data.items;
    if (extra > extras.len or extras.len - extra <= ast_mod.FunctionExtra.flags) return false;
    const flags = extras[extra + ast_mod.FunctionExtra.flags];
    if ((flags & (ast_mod.FunctionFlags.is_async | ast_mod.FunctionFlags.is_generator)) != 0) return false;
    const name_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + ast_mod.FunctionExtra.name]));
    if (!isBoundSourceIdentifierBinding(ast, semantic, name_idx)) return false;

    const name_raw = @backingInt(name_idx);
    if (name_raw >= semantic.symbol_ids.len) return false;
    const symbol_raw = semantic.symbol_ids[name_raw] orelse return false;
    if (symbol_raw >= semantic.symbols.items.len) return false;
    const symbol = semantic.symbols.items[symbol_raw];
    if (!symbol.kind.isFunctionLike() or symbol.scope_id.isNone() or
        symbol.scope_id != symbol.origin_scope or @backingInt(symbol.scope_id) >= semantic.scopes.len) return false;
    const scope = semantic.scopes[@backingInt(symbol.scope_id)];
    if (scope.kind != .switch_block or !scope.is_strict) return false;

    const name = ast.getNode(name_idx);
    return symbol.name.start == name.span.start and symbol.name.end == name.span.end and
        symbol.declaration_span.start == declaration.span.start and
        symbol.declaration_span.end == declaration.span.end;
}

fn isSafePostSuperSwitchCase(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    case_idx: ast_mod.NodeIndex,
) bool {
    if (case_idx.isNone() or @backingInt(case_idx) >= ast.nodes.items.len) return false;
    const switch_case = ast.getNode(case_idx);
    if (switch_case.tag != .switch_case) return false;
    const extras = ast.extra_data.items;
    const extra = switch_case.data.extra;
    if (extra > extras.len or extras.len - extra < 3) return false;
    const test_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
    const statements_start = extras[extra + 1];
    const statements_len = extras[extra + 2];
    if ((!test_idx.isNone() and !isSafeConstructorValue(ast, semantic, test_idx)) or
        statements_start > extras.len or statements_len > extras.len - statements_start) return false;

    for (extras[statements_start .. statements_start + statements_len], 0..) |raw_statement_idx, index| {
        if (raw_statement_idx >= ast.nodes.items.len) return false;
        const case_statement_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw_statement_idx));
        const case_statement = ast.getNode(case_statement_idx);
        if (index + 1 == statements_len) {
            if (isSafePostSuperDerivedConstructorReturnStatement(ast, semantic, case_statement_idx) or
                isSafePostSuperDerivedConstructorThrowStatement(ast, semantic, case_statement_idx)) return true;
            if (case_statement.tag == .break_statement and case_statement.data.unary.operand.isNone()) return true;
        }
        if (isSafeStrictSwitchBlockFunctionDeclaration(ast, semantic, case_statement_idx)) continue;
        if (isSafeConstructorVarDeclaration(ast, semantic, case_statement) or
            isSafePostSuperSwitchExpressionStatement(ast, semantic, case_statement_idx)) continue;
        return false;
    }
    return true;
}

fn isSafePostSuperSwitchStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement_idx: ast_mod.NodeIndex,
) bool {
    if (statement_idx.isNone() or @backingInt(statement_idx) >= ast.nodes.items.len) return false;
    const statement = ast.getNode(statement_idx);
    if (statement.tag != .switch_statement) return false;
    const extras = ast.extra_data.items;
    const extra = statement.data.extra;
    if (extra > extras.len or extras.len - extra < 3) return false;
    const discriminant_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
    const cases_start = extras[extra + 1];
    const cases_len = extras[extra + 2];
    if (!isSafeConstructorValue(ast, semantic, discriminant_idx) or
        cases_start > extras.len or cases_len > extras.len - cases_start) return false;
    for (extras[cases_start .. cases_start + cases_len]) |raw_case_idx| {
        if (raw_case_idx >= ast.nodes.items.len or
            !isSafePostSuperSwitchCase(ast, semantic, @fromBackingInt(@intCast(raw_case_idx)))) return false;
    }
    return true;
}

fn isSafePostSuperTryStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement_idx: ast_mod.NodeIndex,
) bool {
    if (statement_idx.isNone() or @backingInt(statement_idx) >= ast.nodes.items.len or
        ast.getNode(statement_idx).tag != .try_statement or
        !isSafeConstructorBodyStatement(ast, semantic, statement_idx)) return false;

    // A try/catch clause introduces nested scopes. Until generated `this`
    // references in those scopes have an exact owner mapping, keep such
    // statements on semantic reanalysis.
    return !hasThisExpressionInSubtree(ast, statement_idx);
}

fn hasThisExpressionInSubtree(ast: *const ast_mod.Ast, root_idx: ast_mod.NodeIndex) bool {
    const descendants = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, root_idx) catch return true;
    defer ast.allocator.free(descendants);
    for (descendants) |raw_idx| {
        if (raw_idx >= ast.nodes.items.len or ast.nodes.items[raw_idx].tag == .this_expression) return true;
    }
    return false;
}

fn areSafePostSuperNestedScopes(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    root_idx: ast_mod.NodeIndex,
) bool {
    const descendants = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, root_idx) catch return false;
    defer ast.allocator.free(descendants);
    for (descendants) |raw_idx| {
        if (raw_idx >= ast.nodes.items.len) return false;
        const descendant_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw_idx));
        const descendant = ast.nodes.items[raw_idx];
        switch (descendant.tag) {
            .switch_statement => if (!isSafePostSuperSwitchStatement(ast, semantic, descendant_idx)) return false,
            .try_statement => if (!isSafePostSuperTryStatement(ast, semantic, descendant_idx)) return false,
            else => {},
        }
    }
    return true;
}

fn isSafePostSuperLoopStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement_idx: ast_mod.NodeIndex,
) bool {
    if (statement_idx.isNone() or @backingInt(statement_idx) >= ast.nodes.items.len) return false;
    const statement = ast.getNode(statement_idx);
    switch (statement.tag) {
        .for_statement, .while_statement, .do_while_statement, .for_in_statement, .for_of_statement => {},
        else => return false,
    }
    if (!isSafeConstructorBodyStatement(ast, semantic, statement_idx)) return false;

    // The recursive constructor-body check validates each loop's header and
    // body; this pass adds the post-super-specific nested switch/try gates.
    return areSafePostSuperNestedScopes(ast, semantic, statement_idx);
}

fn isSafePostSuperBlockOrLabelStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement_idx: ast_mod.NodeIndex,
) bool {
    if (statement_idx.isNone() or @backingInt(statement_idx) >= ast.nodes.items.len) return false;
    switch (ast.getNode(statement_idx).tag) {
        .block_statement, .labeled_statement => {},
        else => return false,
    }
    if (!isSafeConstructorBodyStatement(ast, semantic, statement_idx)) return false;

    // Blocks and labels can wrap nested loops, switches, and try scopes. Apply
    // the same deeper scope checks used when a loop is the top-level node.
    return areSafePostSuperNestedScopes(ast, semantic, statement_idx);
}

fn isSafePostSuperNonCompletingBlockOrLabelStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement_idx: ast_mod.NodeIndex,
) bool {
    if (!isSafePostSuperBlockOrLabelStatement(ast, semantic, statement_idx)) return false;
    const descendants = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, statement_idx) catch return false;
    defer ast.allocator.free(descendants);
    for (descendants) |raw_idx| {
        if (raw_idx >= ast.nodes.items.len) return false;
        switch (ast.nodes.items[raw_idx].tag) {
            // A nested wrapper must not bypass the branch's explicit terminal
            // return/throw checks. Keep those shapes on semantic reanalysis.
            .return_statement, .throw_statement => return false,
            else => {},
        }
    }
    return true;
}

fn isSimpleParamsConstructorBodyGraphSafe(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    method_extra: u32,
) bool {
    const extras = ast.extra_data.items;
    if (method_extra > extras.len or extras.len - method_extra <= ast_mod.MethodExtra.body) return false;

    const params_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[method_extra + ast_mod.MethodExtra.params]));
    if (params_idx.isNone() or @backingInt(params_idx) >= ast.nodes.items.len) return false;
    const params = ast.getNode(params_idx);
    if (params.tag != .formal_parameters or params.data.list.start > extras.len or
        params.data.list.len > extras.len - params.data.list.start) return false;
    for (extras[params.data.list.start .. params.data.list.start + params.data.list.len], 0..) |raw_parameter_idx, parameter_offset| {
        if (!isSimpleConstructorParameterGraphSafe(
            ast,
            semantic,
            @fromBackingInt(@intCast(raw_parameter_idx)),
            params.data.list,
            @intCast(parameter_offset),
        )) return false;
    }

    const body_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[method_extra + ast_mod.MethodExtra.body]));
    if (body_idx.isNone() or @backingInt(body_idx) >= ast.nodes.items.len) return false;
    const body = ast.getNode(body_idx);
    if (body.tag != .block_statement) return false;
    const statements = body.data.list;
    if (statements.start > extras.len or statements.len > extras.len - statements.start) return false;
    if (statements.len > 0) {
        const super_statement: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[statements.start]));
        if (isSafeSuperConstructorStatement(ast, semantic, super_statement)) {
            // Keep the initialization boundary explicit: simple `var`
            // declarations, direct `super` property reads and assignments,
            // direct `this` writes, and bounded conditionals with simple
            // branch blocks may follow, with an optional final return or throw.
            var completion_seen = false;
            for (extras[statements.start + 1 .. statements.start + statements.len]) |raw_statement_idx| {
                if (raw_statement_idx >= ast.nodes.items.len) return false;
                const following_statement: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw_statement_idx));
                if (!completion_seen and isSafePostSuperVarDeclaration(
                    ast,
                    semantic,
                    ast.getNode(following_statement),
                )) continue;
                if (!completion_seen and isSafePostSuperExpressionStatement(
                    ast,
                    semantic,
                    following_statement,
                )) continue;
                if (!completion_seen and isSafePostSuperConditionalStatement(
                    ast,
                    semantic,
                    following_statement,
                )) continue;
                if (!completion_seen and isSafePostSuperSwitchStatement(
                    ast,
                    semantic,
                    following_statement,
                )) continue;
                if (!completion_seen and isSafePostSuperTryStatement(
                    ast,
                    semantic,
                    following_statement,
                )) continue;
                if (!completion_seen and isSafePostSuperLoopStatement(
                    ast,
                    semantic,
                    following_statement,
                )) continue;
                if (!completion_seen and isSafePostSuperBlockOrLabelStatement(
                    ast,
                    semantic,
                    following_statement,
                )) continue;
                if (!completion_seen and (ast.getNode(following_statement).tag == .empty_statement or
                    ast.getNode(following_statement).tag == .debugger_statement)) continue;
                if (!completion_seen and
                    (isSafePostSuperDerivedConstructorReturnStatement(ast, semantic, following_statement) or
                        isSafePostSuperDerivedConstructorThrowStatement(ast, semantic, following_statement)))
                {
                    completion_seen = true;
                    continue;
                }
                return false;
            }
            return true;
        }
    }
    for (extras[statements.start .. statements.start + statements.len]) |raw_statement_idx| {
        if (raw_statement_idx >= ast.nodes.items.len or
            !isSafeConstructorBodyStatement(ast, semantic, @fromBackingInt(@intCast(raw_statement_idx)))) return false;
    }
    return true;
}

/// Static computed field keys are memoized outside the class key node. A read
/// of the class's inner name can depend on the class-body binding's TDZ and
/// must not be admitted to that path. The key allowlist separately validates
/// every source reference; this scan only rejects references to inner class
/// symbols.
fn hasClassSelfReference(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    expression_idx: ast_mod.NodeIndex,
) bool {
    const descendants = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, expression_idx) catch return true;
    defer ast.allocator.free(descendants);
    for (descendants) |raw_idx| {
        if (raw_idx >= ast.nodes.items.len or ast.nodes.items[raw_idx].tag != .identifier_reference) continue;
        if (raw_idx >= semantic.symbol_ids.len) continue;
        const reference_symbol = semantic.symbol_ids[raw_idx] orelse continue;
        var class_self_symbols = semantic.class_self_symbol_map.valueIterator();
        while (class_self_symbols.next()) |class_self_symbol| {
            if (reference_symbol == class_self_symbol.*) return true;
        }
    }
    return false;
}

/// A public static field stays on the edited graph when its initializer and
/// computed key use safe values, exact-bound references, or unresolved source
/// references/calls admitted by the shared expression validator. `this`,
/// unresolved `require` calls, call-result member receivers, and unsafe
/// call/member forms stay on resync.
fn isRetainableSimpleStaticClassField(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node: ast_mod.Node,
) bool {
    if (node.tag != .property_definition) return false;
    const extras = ast.extra_data.items;
    const extra = node.data.extra;
    if (extra > extras.len or extras.len - extra <= ast_mod.PropertyExtra.deco_len) return false;

    const flags = extras[extra + ast_mod.PropertyExtra.flags];
    const unsupported_flags = ast_mod.PropertyFlags.is_abstract |
        ast_mod.PropertyFlags.is_declare |
        ast_mod.PropertyFlags.flow_variance;
    const allowed_flags = ast_mod.PropertyFlags.is_static | unsupported_flags;
    if ((flags & ast_mod.PropertyFlags.is_static) == 0 or
        (flags & unsupported_flags) != 0 or (flags & ~allowed_flags) != 0 or
        extras[extra + ast_mod.PropertyExtra.deco_len] != 0) return false;

    const key_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + ast_mod.PropertyExtra.key]));
    const init_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + ast_mod.PropertyExtra.init]));
    if (key_idx.isNone() or @backingInt(key_idx) >= ast.nodes.items.len or
        init_idx.isNone() or @backingInt(init_idx) >= ast.nodes.items.len) return false;
    const key = ast.getNode(key_idx);
    switch (key.tag) {
        .identifier_reference => if (std.mem.eql(u8, ast.getText(key.span), "__proto__")) return false,
        .computed_property_key => {
            const key_value_idx = key.data.unary.operand;
            if (key_value_idx.isNone() or @backingInt(key_value_idx) >= ast.nodes.items.len or
                hasClassSelfReference(ast, semantic, key_value_idx) or
                (!isSafeConstructorValue(ast, semantic, key_value_idx) and
                    !isUnresolvedSourceIdentifierReference(ast, semantic, key_value_idx) and
                    !isRetainableStaticFieldOptionalMemberChain(
                        allocator,
                        ast,
                        semantic,
                        key_value_idx,
                        true,
                        false,
                    ) and
                    !isRetainableStaticFieldMemberAccess(allocator, ast, semantic, key_value_idx) and
                    !isRetainableStaticFieldCall(allocator, ast, semantic, key_value_idx, true, false, false))) return false;
        },
        else => return false,
    }
    return isSafeConstructorValue(ast, semantic, init_idx) or
        isUnresolvedSourceIdentifierReference(ast, semantic, init_idx) or
        isRetainableStaticFieldInitializerMemberAccess(allocator, ast, semantic, init_idx) or
        isRetainableStaticFieldCall(allocator, ast, semantic, init_idx, true, true, false);
}

fn hasReachableStaticPublicClassField(ast: *const ast_mod.Ast) ?bool {
    if (ast.nodes.items.len == 0) return false;
    const root_idx = ast.transformed_root orelse @as(
        ast_mod.NodeIndex,
        @fromBackingInt(@intCast(@as(u32, @intCast(ast.nodes.items.len - 1)))),
    );
    if (root_idx.isNone() or @backingInt(root_idx) >= ast.nodes.items.len) return null;
    const reachable = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, root_idx) catch return null;
    defer ast.allocator.free(reachable);
    for (reachable) |raw| {
        if (raw >= ast.nodes.items.len) continue;
        const node = ast.nodes.items[raw];
        if (node.tag != .property_definition) continue;
        const extras = ast.extra_data.items;
        const extra = node.data.extra;
        if (extra > extras.len or extras.len - extra <= ast_mod.PropertyExtra.flags) continue;
        const flags = extras[extra + ast_mod.PropertyExtra.flags];
        if ((flags & ast_mod.PropertyFlags.is_static) == 0 or
            extras.len - extra <= ast_mod.PropertyExtra.init) continue;
        const key_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + ast_mod.PropertyExtra.key]));
        const init_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + ast_mod.PropertyExtra.init]));
        if (key_idx.isNone() or @backingInt(key_idx) >= ast.nodes.items.len or
            ast.nodes.items[@backingInt(key_idx)].tag == .private_identifier or
            init_idx.isNone() or @backingInt(init_idx) >= ast.nodes.items.len) continue;
        return true;
    }
    return false;
}

/// A downleveled class preserves its graph when it has no base or a simple
/// bound identifier base, and contains supported plain methods, optionally
/// followed by one accessor or a compatible getter/setter pair. ES5 async
/// class methods are admitted when their state-machine scopes pass the retained
/// async preflight. A derived class method may use `super` only directly in its
/// body, where its exact home-object reference remains in the class scope.
/// One explicit constructor with only simple identifier parameters or
/// identifier parameters with literal defaults may accompany those members
/// when its body contains only audited declarations, expressions, control
/// flow, and loops. Named or anonymous class expressions are admitted only as
/// direct initializers of a `var` declarator; other expression positions stay
/// on reanalysis.
/// Anonymous expressions are safe because lowering registers the generated
/// constructor self binding and call-check reference in the exact output
/// function scope. Static fields must pass
/// `isRetainableSimpleStaticClassField`; unsafe computed/escaped keys, class-self
/// heritage reads, and nested lexical `super` outside the audited async-class-
/// method shapes stay excluded. Direct `super` in synchronous methods and async
/// instance/static methods stays tied to the owning class home; one synchronous
/// arrow scope may also capture an async method's use. Async-arrow super uses
/// retain their separate single-arrow home-object preflight.
fn isSimpleClass(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node: ast_mod.Node,
    raw_node: usize,
    source_object_shadows_class: bool,
    allow_es5_async_arrow_super: bool,
    allow_es5_async_class_methods: bool,
) bool {
    if (node.tag != .class_declaration and node.tag != .class_expression) return false;
    const extra = node.data.extra;
    const extras = ast.extra_data.items;
    if (extra > extras.len or extras.len - extra <= ast_mod.ClassExtra.body) return false;

    const name: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + ast_mod.ClassExtra.name]));
    const super: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + ast_mod.ClassExtra.super]));
    const body: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + ast_mod.ClassExtra.body]));
    if ((!name.isNone() and (@backingInt(name) >= ast.nodes.items.len or
        ast.getNode(name).tag != .binding_identifier)) or
        (name.isNone() and node.tag != .class_expression) or
        (!super.isNone() and !isBoundSourceIdentifierReference(ast, semantic, super)) or
        body.isNone() or @backingInt(body) >= ast.nodes.items.len) return false;
    if (!name.isNone() and !super.isNone()) {
        if (!isBoundSourceIdentifierBinding(ast, semantic, name)) return false;
        const name_symbol = semantic.symbol_ids[@backingInt(name)] orelse return false;
        const super_symbol = semantic.symbol_ids[@backingInt(super)] orelse return false;
        const class_self_symbol = semantic.class_self_symbol_map.get(@intCast(raw_node));
        // A declaration can resolve its own name in the heritage clause while
        // that lexical binding is still in the TDZ. Lowering it through the
        // generated constructor would change the thrown error and can detach
        // the read from its valid source scope.
        if (name_symbol == super_symbol or
            (class_self_symbol != null and class_self_symbol.? == super_symbol)) return false;
    }
    const body_node = ast.getNode(body);
    if (body_node.tag != .class_body) return false;
    const members = body_node.data.list;
    if (members.len == 0) return true;
    if (source_object_shadows_class) return false;
    if (members.start > extras.len or members.len > extras.len - members.start) return false;

    var accessor_pair: ?struct { flags: u32, key_text: []const u8 } = null;
    var accessor_count: usize = 0;
    var accessors_started = false;
    var has_empty_explicit_constructor = false;
    for (extras[members.start .. members.start + members.len]) |raw_member_idx| {
        const member_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw_member_idx));
        if (member_idx.isNone() or @backingInt(member_idx) >= ast.nodes.items.len) return false;
        const member = ast.getNode(member_idx);
        if (isRetainableSimpleStaticClassField(allocator, ast, semantic, member)) continue;
        if (member.tag != .method_definition) return false;
        const method_extra = member.data.extra;
        if (method_extra > extras.len or extras.len - method_extra <= ast_mod.MethodExtra.flags) return false;
        const key_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[method_extra + ast_mod.MethodExtra.key]));
        if (key_idx.isNone() or @backingInt(key_idx) >= ast.nodes.items.len) return false;
        const key = ast.getNode(key_idx);
        const flags = extras[method_extra + ast_mod.MethodExtra.flags];
        const is_es5_async_instance_method = flags == ast_mod.MethodFlags.is_async;
        const is_es5_async_static_method = flags ==
            (ast_mod.MethodFlags.is_async | ast_mod.MethodFlags.is_static);
        const is_es5_async_method = allow_es5_async_class_methods and
            (is_es5_async_instance_method or is_es5_async_static_method);
        const is_plain_method = flags == 0 or flags == ast_mod.MethodFlags.is_static or is_es5_async_method;
        const is_plain_accessor = flags == ast_mod.MethodFlags.is_getter or
            flags == ast_mod.MethodFlags.is_setter or
            flags == (ast_mod.MethodFlags.is_static | ast_mod.MethodFlags.is_getter) or
            flags == (ast_mod.MethodFlags.is_static | ast_mod.MethodFlags.is_setter);
        if (key.tag != .identifier_reference or (!is_plain_method and !is_plain_accessor)) return false;
        const key_text = ast.getText(key.span);
        if (std.mem.eql(u8, key_text, "constructor")) {
            if (has_empty_explicit_constructor or flags != 0 or
                !isSimpleParamsConstructorBodyGraphSafe(ast, semantic, method_extra)) return false;
            has_empty_explicit_constructor = true;
            continue;
        }
        if (is_plain_accessor) {
            accessors_started = true;
            if (accessor_pair) |previous| {
                const same_staticness =
                    (previous.flags & ast_mod.MethodFlags.is_static) ==
                    (flags & ast_mod.MethodFlags.is_static);
                const previous_is_getter = (previous.flags & ast_mod.MethodFlags.is_getter) != 0;
                const current_is_getter = (flags & ast_mod.MethodFlags.is_getter) != 0;
                if (!same_staticness or previous_is_getter == current_is_getter or
                    !std.mem.eql(u8, previous.key_text, key_text)) return false;
            } else {
                accessor_pair = .{ .flags = flags, .key_text = key_text };
            }
            accessor_count += 1;
        } else if (accessors_started) {
            // Class lowering emits every ordinary method before its accessor
            // descriptors. Keep source order observable on the retained path.
            return false;
        }
        const has_super = methodHasSuperExpression(ast, member);
        const retains_async_arrow_super = allow_es5_async_arrow_super and !super.isNone() and
            (flags == 0 or flags == ast_mod.MethodFlags.is_static) and
            methodSuperUsesInAsyncArrowScopesOrDirectBody(ast, member, false);
        const retains_async_class_method_super =
            (is_es5_async_instance_method or is_es5_async_static_method) and
            allow_es5_async_class_methods and !super.isNone() and
            methodSuperUsesOnlyDirectMethodBody(ast, member);
        const retains_async_class_method_sync_arrow_super =
            (is_es5_async_instance_method or is_es5_async_static_method) and
            allow_es5_async_class_methods and !super.isNone() and
            methodSuperUsesOnlySingleSyncArrow(ast, member);
        const retains_async_class_method_arrow_super =
            (is_es5_async_instance_method or is_es5_async_static_method) and
            allow_es5_async_class_methods and !super.isNone() and
            methodSuperUsesOnlyUniformAsyncArrowScopes(ast, member);
        const retains_sync_class_method_super =
            (flags == 0 or flags == ast_mod.MethodFlags.is_static) and
            !super.isNone() and methodSuperUsesOnlyDirectMethodBody(ast, member);
        if (std.mem.eql(u8, key_text, "constructor") or std.mem.eql(u8, key_text, "__proto__") or
            std.mem.indexOfScalar(u8, key_text, '\\') != null or
            (has_super and !retains_async_arrow_super and !retains_async_class_method_super and
                !retains_async_class_method_sync_arrow_super and
                !retains_async_class_method_arrow_super and !retains_sync_class_method_super)) return false;
    }
    if (accessor_count > 2) return false;
    if (accessor_pair) |accessor| {
        // A method with the same key would replace or be replaced by the
        // accessor descriptor. Keep that duplicate-definition order on resync.
        const accessor_is_static = (accessor.flags & ast_mod.MethodFlags.is_static) != 0;
        for (extras[members.start .. members.start + members.len]) |raw_member_idx| {
            const member = ast.getNode(@fromBackingInt(@intCast(raw_member_idx)));
            if (member.tag != .method_definition) continue;
            const method_extra = member.data.extra;
            const flags = extras[method_extra + ast_mod.MethodExtra.flags];
            const is_plain_method = flags == 0 or flags == ast_mod.MethodFlags.is_static or
                (allow_es5_async_class_methods and
                    (flags == ast_mod.MethodFlags.is_async or
                        flags == (ast_mod.MethodFlags.is_async | ast_mod.MethodFlags.is_static)));
            if (!is_plain_method or ((flags & ast_mod.MethodFlags.is_static) != 0) != accessor_is_static) continue;
            const key_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[method_extra + ast_mod.MethodExtra.key]));
            const key_text = ast.getText(ast.getNode(key_idx).span);
            if (std.mem.eql(u8, accessor.key_text, key_text)) return false;
        }
    }
    return true;
}

fn collectDirectVarClassExpressions(
    ast: *const ast_mod.Ast,
    reachable_nodes: []const u32,
    class_expressions: *std.AutoHashMapUnmanaged(u32, void),
) bool {
    const extras = ast.extra_data.items;
    for (reachable_nodes) |raw_statement| {
        if (raw_statement >= ast.nodes.items.len) return false;
        const statement = ast.nodes.items[raw_statement];
        if (statement.tag != .variable_declaration or
            ast.variableDeclarationKind(statement) != .@"var") continue;
        const declaration_extra = statement.data.extra;
        if (declaration_extra > extras.len or extras.len - declaration_extra < 3) return false;
        const declarators_start = extras[declaration_extra + 1];
        const declarators_len = extras[declaration_extra + 2];
        if (declarators_start > extras.len or declarators_len > extras.len - declarators_start) return false;
        for (extras[declarators_start .. declarators_start + declarators_len]) |raw_declarator| {
            if (raw_declarator >= ast.nodes.items.len) return false;
            const declarator = ast.nodes.items[raw_declarator];
            if (declarator.tag != .variable_declarator) return false;
            const declarator_extra = declarator.data.extra;
            if (declarator_extra > extras.len or extras.len - declarator_extra < 3) return false;
            const initializer_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[declarator_extra + 2]));
            if (initializer_idx.isNone()) continue;
            const initializer_raw = @backingInt(initializer_idx);
            if (initializer_raw >= ast.nodes.items.len) return false;
            if (ast.nodes.items[initializer_raw].tag != .class_expression) continue;
            class_expressions.put(ast.allocator, initializer_raw, {}) catch return false;
        }
    }
    return true;
}

fn collectDirectFunctionBodyClassDeclarations(
    ast: *const ast_mod.Ast,
    reachable_nodes: []const u32,
    class_declarations: *std.AutoHashMapUnmanaged(u32, void),
) bool {
    for (reachable_nodes) |raw_function| {
        if (raw_function >= ast.nodes.items.len) return false;
        const function = ast.nodes.items[raw_function];
        const body_idx = ast.functionBodyBlock(function) orelse continue;
        if (@backingInt(body_idx) >= ast.nodes.items.len) return false;
        const body = ast.getNode(body_idx);
        if (body.tag != .block_statement and body.tag != .function_body) continue;
        const statements = body.data.list;
        if (statements.start > ast.extra_data.items.len or
            statements.len > ast.extra_data.items.len - statements.start) return false;
        for (ast.extra_data.items[statements.start .. statements.start + statements.len]) |raw_statement| {
            if (raw_statement >= ast.nodes.items.len) return false;
            if (ast.nodes.items[raw_statement].tag == .class_declaration)
                class_declarations.put(ast.allocator, raw_statement, {}) catch return false;
        }
    }
    return true;
}

fn isRetainableGraphClass(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node: ast_mod.Node,
    raw_node: usize,
    top_level_statements: *const std.DynamicBitSet,
    function_body_class_declarations: *const std.AutoHashMapUnmanaged(u32, void),
    direct_var_class_expressions: *const std.AutoHashMapUnmanaged(u32, void),
    source_object_shadows_class: bool,
    allow_es5_async_arrow_super: bool,
    allow_es5_async_class_methods: bool,
) bool {
    const raw: u32 = @intCast(raw_node);
    const has_safe_owner = switch (node.tag) {
        .class_declaration => top_level_statements.isSet(raw_node) or function_body_class_declarations.contains(raw),
        .class_expression => direct_var_class_expressions.contains(raw),
        else => false,
    };
    return has_safe_owner and isSimpleClass(
        allocator,
        ast,
        semantic,
        node,
        raw_node,
        source_object_shadows_class,
        allow_es5_async_arrow_super,
        allow_es5_async_class_methods,
    );
}

fn registerRetainableEs5AsyncClassMethods(
    ast: *const ast_mod.Ast,
    class_node: ast_mod.Node,
    retained_async_functions: *std.AutoHashMapUnmanaged(u32, void),
) bool {
    if (class_node.tag != .class_declaration and class_node.tag != .class_expression) return false;
    const class_extra = class_node.data.extra;
    if (class_extra > ast.extra_data.items.len or
        ast.extra_data.items.len - class_extra <= ast_mod.ClassExtra.body) return false;
    const super_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[class_extra + ast_mod.ClassExtra.super]));
    const body_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[class_extra + ast_mod.ClassExtra.body]));
    if (body_idx.isNone() or @backingInt(body_idx) >= ast.nodes.items.len or
        ast.getNode(body_idx).tag != .class_body) return false;
    const members = ast.getNode(body_idx).data.list;
    if (members.start > ast.extra_data.items.len or
        members.len > ast.extra_data.items.len - members.start) return false;
    for (ast.extra_data.items[members.start .. members.start + members.len]) |raw_member_idx| {
        if (raw_member_idx >= ast.nodes.items.len) return false;
        const member = ast.nodes.items[raw_member_idx];
        if (member.tag != .method_definition) continue;
        const method_extra = member.data.extra;
        if (method_extra > ast.extra_data.items.len or
            ast.extra_data.items.len - method_extra <= ast_mod.MethodExtra.flags) return false;
        const flags = ast.extra_data.items[method_extra + ast_mod.MethodExtra.flags];
        const is_async_instance_method = flags == ast_mod.MethodFlags.is_async;
        const is_async_static_method = flags ==
            (ast_mod.MethodFlags.is_async | ast_mod.MethodFlags.is_static);
        if (!is_async_instance_method and !is_async_static_method) continue;
        if (methodHasSuperExpression(ast, member) and
            (super_idx.isNone() or
                (!methodSuperUsesOnlyDirectMethodBody(ast, member) and
                    !methodSuperUsesOnlySingleSyncArrow(ast, member) and
                    !methodSuperUsesOnlyUniformAsyncArrowScopes(ast, member)))) return false;
        retained_async_functions.put(ast.allocator, raw_member_idx, {}) catch return false;
    }
    return true;
}

// Downlevel class methods keep direct-body `super` accesses tied to their
// source method and exact class home object. A synchronous method can also
// retain `super` used only inside async arrows whose state-machine preflight
// has already admitted those exact owners. Other nested scopes remain on
// resync.
fn registerRetainableSyncClassSuperMethods(
    ast: *const ast_mod.Ast,
    class_node: ast_mod.Node,
    retained_sync_super_methods: *std.AutoHashMapUnmanaged(u32, void),
) bool {
    if (class_node.tag != .class_declaration and class_node.tag != .class_expression) return false;
    const class_extra = class_node.data.extra;
    if (class_extra > ast.extra_data.items.len or
        ast.extra_data.items.len - class_extra <= ast_mod.ClassExtra.body) return false;
    const super_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[class_extra + ast_mod.ClassExtra.super]));
    const body_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[class_extra + ast_mod.ClassExtra.body]));
    if (body_idx.isNone() or @backingInt(body_idx) >= ast.nodes.items.len or
        ast.getNode(body_idx).tag != .class_body) return false;
    const members = ast.getNode(body_idx).data.list;
    if (members.start > ast.extra_data.items.len or
        members.len > ast.extra_data.items.len - members.start) return false;
    for (ast.extra_data.items[members.start .. members.start + members.len]) |raw_member_idx| {
        if (raw_member_idx >= ast.nodes.items.len) return false;
        const member = ast.nodes.items[raw_member_idx];
        if (member.tag != .method_definition or !methodHasSuperExpression(ast, member)) continue;
        const method_extra = member.data.extra;
        if (method_extra > ast.extra_data.items.len or
            ast.extra_data.items.len - method_extra <= ast_mod.MethodExtra.flags) return false;
        const flags = ast.extra_data.items[method_extra + ast_mod.MethodExtra.flags];
        if (flags != 0 and flags != ast_mod.MethodFlags.is_static) continue;
        if (super_idx.isNone() or
            (!methodSuperUsesOnlyDirectMethodBody(ast, member) and
                !methodSuperUsesInAsyncArrowScopesOrDirectBody(ast, member, false))) return false;
        retained_sync_super_methods.put(ast.allocator, raw_member_idx, {}) catch return false;
    }
    return true;
}

fn collectSimpleConstructorDefaultParameterNodes(
    ast: *const ast_mod.Ast,
    class_node: ast_mod.Node,
    defaults: *std.AutoHashMapUnmanaged(u32, void),
) bool {
    const extras = ast.extra_data.items;
    const class_extra = class_node.data.extra;
    if (class_extra > extras.len or extras.len - class_extra <= ast_mod.ClassExtra.body) return false;
    const body_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[class_extra + ast_mod.ClassExtra.body]));
    if (body_idx.isNone() or @backingInt(body_idx) >= ast.nodes.items.len or
        ast.getNode(body_idx).tag != .class_body) return false;
    const members = ast.getNode(body_idx).data.list;
    if (members.start > extras.len or members.len > extras.len - members.start) return false;
    for (extras[members.start .. members.start + members.len]) |raw_member_idx| {
        if (raw_member_idx >= ast.nodes.items.len) return false;
        const member = ast.nodes.items[raw_member_idx];
        if (member.tag != .method_definition) continue;
        const method_extra = member.data.extra;
        if (method_extra > extras.len or extras.len - method_extra <= ast_mod.MethodExtra.flags) return false;
        const key_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[method_extra + ast_mod.MethodExtra.key]));
        if (key_idx.isNone() or @backingInt(key_idx) >= ast.nodes.items.len) return false;
        const key = ast.getNode(key_idx);
        if (key.tag != .identifier_reference or !std.mem.eql(u8, ast.getText(key.span), "constructor")) continue;
        if (extras[method_extra + ast_mod.MethodExtra.flags] != 0 or
            extras.len - method_extra <= ast_mod.MethodExtra.params) return false;
        const params_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[method_extra + ast_mod.MethodExtra.params]));
        if (params_idx.isNone() or @backingInt(params_idx) >= ast.nodes.items.len or
            ast.getNode(params_idx).tag != .formal_parameters) return false;
        const params = ast.getNode(params_idx).data.list;
        if (params.start > extras.len or params.len > extras.len - params.start) return false;
        for (extras[params.start .. params.start + params.len]) |raw_parameter_idx| {
            if (raw_parameter_idx >= ast.nodes.items.len) return false;
            if (ast.nodes.items[raw_parameter_idx].tag == .assignment_pattern)
                defaults.put(ast.allocator, raw_parameter_idx, {}) catch return false;
        }
    }
    return true;
}

fn collectRetainedPreflightParents(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    root: ast_mod.NodeIndex,
    parents: *std.AutoHashMapUnmanaged(u32, u32),
) bool {
    const VisitState = enum { visiting, visited };
    const Frame = struct { node: ast_mod.NodeIndex, parent: ?u32 = null, exit: bool = false };
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len) return false;

    var states: std.AutoHashMapUnmanaged(u32, VisitState) = .empty;
    defer states.deinit(allocator);
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);
    stack.append(allocator, .{ .node = root }) catch return false;

    while (stack.pop()) |frame| {
        if (frame.node.isNone() or @backingInt(frame.node) >= ast.nodes.items.len) return false;
        const raw = @backingInt(frame.node);
        if (frame.exit) {
            states.put(allocator, raw, .visited) catch return false;
            continue;
        }
        if (frame.parent) |parent| {
            const parent_entry = parents.getOrPut(allocator, raw) catch return false;
            if (parent_entry.found_existing and parent_entry.value_ptr.* != parent) return false;
            if (!parent_entry.found_existing) parent_entry.value_ptr.* = parent;
        }
        if (states.get(raw)) |state| {
            if (state == .visiting) return false;
            continue;
        }
        states.put(allocator, raw, .visiting) catch return false;
        stack.append(allocator, .{ .node = frame.node, .exit = true }) catch return false;

        var children = ast_walk.children(ast, ast.getNode(frame.node));
        while (children.next()) |child| {
            if (child.isNone()) continue;
            if (@backingInt(child) >= ast.nodes.items.len) return false;
            stack.append(allocator, .{ .node = child, .parent = raw }) catch return false;
        }
    }
    return true;
}

fn scopeChainContainsBinding(
    semantic: *const ModuleSemanticData,
    starting_scope: u32,
    name: []const u8,
) bool {
    var scope = starting_scope;
    var hops: usize = 0;
    while (hops < semantic.scopes.len) : (hops += 1) {
        if (scope >= semantic.scopes.len or scope >= semantic.scope_maps.len) return true;
        if (semantic.scope_maps[scope].contains(name)) return true;
        const parent = semantic.scopes[scope].parent;
        if (parent.isNone()) return false;
        scope = parent.toIndex();
    }
    return true;
}

fn sourceBindingShadowsGeneratedGlobalAtNode(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    parents: *const std.AutoHashMapUnmanaged(u32, u32),
    node: u32,
    name: []const u8,
) bool {
    var current = node;
    var hops: usize = 0;
    while (hops <= ast.nodes.items.len) : (hops += 1) {
        if (semantic.scope_owner_map.get(current)) |scope| {
            return scopeChainContainsBinding(semantic, scope, name);
        }
        current = parents.get(current) orelse return true;
    }
    return true;
}

fn isRetainableAsyncFunctionNode(
    ast: *const ast_mod.Ast,
    node: ast_mod.Node,
    options: TransformOptions,
) bool {
    if (!options.unsupported.async_await) return false;
    if (node.tag != .function_declaration and node.tag != .function_expression and node.tag != .function)
        return false;
    const flags_at = node.data.extra + ast_mod.FunctionExtra.flags;
    if (flags_at >= ast.extra_data.items.len) return false;
    const flags = ast.extra_data.items[flags_at];
    // The ES5 async state-machine path registers its generated wrapper/callback
    // scopes, state binding, and moved body references in the edited graph.
    // Async generators still use their separate conservative resync path.
    return (flags & ast_mod.FunctionFlags.is_async) != 0 and
        (flags & ast_mod.FunctionFlags.is_generator) == 0;
}

fn isPureLiteralUnaryObjectMethodKey(
    ast: *const ast_mod.Ast,
    value: ast_mod.Node,
    allow_other_primitive_literals: bool,
) bool {
    const extras = ast.extra_data.items;
    var current = value;
    var found_unary = false;
    // Walk outer-to-inner: type-changing operators make any outer unary plus
    // safe by preventing it from receiving the underlying BigInt value.
    var plus_before_type_change = false;
    while (current.tag == .unary_expression) {
        found_unary = true;
        const extra = current.data.extra;
        if (extra > extras.len or extras.len - extra < 2) return false;
        const operator: token_mod.Kind = @fromBackingInt(@intCast(@as(u8, @truncate(extras[extra + 1]))));
        switch (operator) {
            .plus => plus_before_type_change = true,
            .minus, .tilde => {},
            .bang, .kw_delete, .kw_typeof, .kw_void => plus_before_type_change = false,
            else => return false,
        }
        const operand_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
        if (operand_idx.isNone() or @backingInt(operand_idx) >= ast.nodes.items.len) return false;
        current = ast.getNode(operand_idx);
    }

    if (!found_unary) return false;
    if (current.tag == .numeric_literal) return true;
    if (current.tag == .bigint_literal) return !plus_before_type_change;
    return allow_other_primitive_literals and
        (current.tag == .string_literal or current.tag == .boolean_literal or current.tag == .null_literal);
}

fn isUnaryObjectMethodKeyEndingInPrimitiveLiteral(
    ast: *const ast_mod.Ast,
    value: ast_mod.Node,
) bool {
    const extras = ast.extra_data.items;
    var current = value;
    var found_unary = false;
    while (current.tag == .unary_expression) {
        found_unary = true;
        const extra = current.data.extra;
        if (extra > extras.len or extras.len - extra < 2) return false;
        const operand_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
        if (operand_idx.isNone() or @backingInt(operand_idx) >= ast.nodes.items.len) return false;
        current = ast.getNode(operand_idx);
    }
    return found_unary and switch (current.tag) {
        .numeric_literal, .bigint_literal, .string_literal, .boolean_literal, .null_literal => true,
        else => false,
    };
}

fn isStaticLiteralObjectMethodKey(ast: *const ast_mod.Ast, key_idx: ast_mod.NodeIndex) bool {
    if (key_idx.isNone() or @backingInt(key_idx) >= ast.nodes.items.len) return false;
    const key = ast.getNode(key_idx);
    const is_computed = key.tag == .computed_property_key;
    const value_idx = if (is_computed) key.data.unary.operand else key_idx;
    if (value_idx.isNone() or @backingInt(value_idx) >= ast.nodes.items.len) return false;
    const value = ast.getNode(value_idx);
    const is_pure_literal_unary_key = is_computed and value.tag == .unary_expression and
        isPureLiteralUnaryObjectMethodKey(ast, value, false);
    return value.tag == .string_literal or
        (is_computed and (value.tag == .numeric_literal or value.tag == .bigint_literal or
            value.tag == .boolean_literal or value.tag == .null_literal or
            is_pure_literal_unary_key or
            (value.tag == .template_literal and value.data.list.len == 0)));
}

fn isRetainableAsyncObjectMethodTemplateExpression(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    expression_idx: ast_mod.NodeIndex,
    traversal_depth: u8,
) bool {
    if (traversal_depth >= 64 or expression_idx.isNone() or
        @backingInt(expression_idx) >= ast.nodes.items.len) return false;
    if (isSafeConstructorValue(ast, semantic, expression_idx)) return true;
    const value = ast.getNode(expression_idx);
    return switch (value.tag) {
        .template_literal => blk: {
            const list = value.data.list;
            if (list.len == 0) break :blk true;
            const extras = ast.extra_data.items;
            if (list.len < 3 or list.len % 2 == 0 or list.start > extras.len or
                list.len > extras.len - list.start) break :blk false;
            var offset: u32 = 1;
            while (offset < list.len) : (offset += 2) {
                const raw_child = extras[list.start + offset];
                if (raw_child >= ast.nodes.items.len or !isRetainableAsyncObjectMethodTemplateExpression(
                    ast,
                    semantic,
                    @fromBackingInt(@intCast(raw_child)),
                    traversal_depth + 1,
                )) break :blk false;
            }
            break :blk true;
        },
        .identifier_reference => isUnresolvedGlobalUndefinedReference(ast, semantic, expression_idx),
        .binary_expression => blk: {
            const operator: token_mod.Kind = @fromBackingInt(@intCast(value.data.binary.flags));
            break :blk isSafeConstructorBinaryOperator(operator) and
                isRetainableAsyncObjectMethodTemplateExpression(
                    ast,
                    semantic,
                    value.data.binary.left,
                    traversal_depth + 1,
                ) and
                isRetainableAsyncObjectMethodTemplateExpression(
                    ast,
                    semantic,
                    value.data.binary.right,
                    traversal_depth + 1,
                );
        },
        .unary_expression => blk: {
            if (isUnaryObjectMethodKeyEndingInPrimitiveLiteral(ast, value))
                break :blk isPureLiteralUnaryObjectMethodKey(ast, value, true);
            const extras = ast.extra_data.items;
            const extra = value.data.extra;
            if (extra > extras.len or extras.len - extra < 2) break :blk false;
            const operator: token_mod.Kind = @fromBackingInt(@intCast(@as(u8, @truncate(extras[extra + 1]))));
            const operand_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
            if (operator == .kw_typeof and
                isUnresolvedSourceIdentifierReference(ast, semantic, operand_idx)) break :blk true;
            if ((operator == .kw_typeof or operator == .kw_void) and
                isInitializedSourceIdentifierReference(ast, semantic, operand_idx)) break :blk true;
            if ((operator == .kw_typeof or operator == .kw_void) and
                isDiscardedSynchronousFunctionExpression(ast, operand_idx)) break :blk true;
            break :blk isSafeConstructorUnaryOperator(operator) and
                isRetainableAsyncObjectMethodTemplateExpression(
                    ast,
                    semantic,
                    operand_idx,
                    traversal_depth + 1,
                );
        },
        .parenthesized_expression => isRetainableAsyncObjectMethodTemplateExpression(
            ast,
            semantic,
            value.data.unary.operand,
            traversal_depth + 1,
        ),
        .static_member_expression => blk: {
            const extras = ast.extra_data.items;
            const extra = value.data.extra;
            if (extra > extras.len or extras.len - extra < 3 or
                (extras[extra + 2] & ast_mod.MemberFlags.optional_chain) != 0) break :blk false;
            const object_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
            break :blk isRetainableAsyncObjectMethodTemplateExpression(
                ast,
                semantic,
                object_idx,
                traversal_depth + 1,
            );
        },
        .computed_member_expression => blk: {
            const extras = ast.extra_data.items;
            const extra = value.data.extra;
            if (extra > extras.len or extras.len - extra < 3 or
                (extras[extra + 2] & ast_mod.MemberFlags.optional_chain) != 0) break :blk false;
            const object_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra]));
            const property_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(extras[extra + 1]));
            break :blk isRetainableAsyncObjectMethodTemplateExpression(
                ast,
                semantic,
                object_idx,
                traversal_depth + 1,
            ) and isRetainableAsyncObjectMethodTemplateExpression(
                ast,
                semantic,
                property_idx,
                traversal_depth + 1,
            );
        },
        .ts_as_expression,
        .ts_satisfies_expression,
        .ts_non_null_expression,
        .ts_type_assertion,
        => isRetainableAsyncObjectMethodTemplateExpression(
            ast,
            semantic,
            value.data.unary.operand,
            traversal_depth + 1,
        ),
        .logical_expression => blk: {
            const operator: token_mod.Kind = @fromBackingInt(@intCast(value.data.binary.flags));
            break :blk isSafeConstructorLogicalOperator(operator) and
                isRetainableAsyncObjectMethodTemplateExpression(
                    ast,
                    semantic,
                    value.data.binary.left,
                    traversal_depth + 1,
                ) and
                isRetainableAsyncObjectMethodTemplateExpression(
                    ast,
                    semantic,
                    value.data.binary.right,
                    traversal_depth + 1,
                );
        },
        .conditional_expression => isRetainableAsyncObjectMethodTemplateExpression(
            ast,
            semantic,
            value.data.ternary.a,
            traversal_depth + 1,
        ) and
            isRetainableAsyncObjectMethodTemplateExpression(
                ast,
                semantic,
                value.data.ternary.b,
                traversal_depth + 1,
            ) and
            isRetainableAsyncObjectMethodTemplateExpression(
                ast,
                semantic,
                value.data.ternary.c,
                traversal_depth + 1,
            ),
        .sequence_expression => blk: {
            const list = value.data.list;
            const extras = ast.extra_data.items;
            if (list.len < 2 or list.start > extras.len or
                list.len > extras.len - list.start) break :blk false;
            for (extras[list.start .. list.start + list.len]) |raw_child| {
                if (raw_child >= ast.nodes.items.len or !isRetainableAsyncObjectMethodTemplateExpression(
                    ast,
                    semantic,
                    @fromBackingInt(@intCast(raw_child)),
                    traversal_depth + 1,
                )) break :blk false;
            }
            break :blk true;
        },
        .bigint_literal => true,
        else => false,
    };
}

fn isRetainableAsyncObjectMethodKey(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    key_idx: ast_mod.NodeIndex,
) bool {
    if (key_idx.isNone() or @backingInt(key_idx) >= ast.nodes.items.len) return false;
    const key = ast.getNode(key_idx);
    if (key.tag == .identifier_reference or isStaticLiteralObjectMethodKey(ast, key_idx)) return true;
    if (key.tag != .computed_property_key) return false;
    const value_idx = key.data.unary.operand;
    if (value_idx.isNone() or @backingInt(value_idx) >= ast.nodes.items.len) return false;
    const value = ast.getNode(value_idx);
    if (value.tag == .template_literal) {
        return isRetainableAsyncObjectMethodTemplateExpression(ast, semantic, value_idx, 0);
    }
    return isSafeConstructorValue(ast, semantic, value_idx);
}

fn isRetainableEs5AsyncObjectMethodNode(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    method_idx: ast_mod.NodeIndex,
    options: TransformOptions,
    parents: *const std.AutoHashMapUnmanaged(u32, u32),
) bool {
    if (!options.unsupported.async_await or !options.unsupported.generator or
        method_idx.isNone() or @backingInt(method_idx) >= ast.nodes.items.len) return false;
    const method = ast.getNode(method_idx);
    if (method.tag != .method_definition) return false;
    const extra = method.data.extra;
    if (extra > ast.extra_data.items.len or
        ast.extra_data.items.len - extra <= ast_mod.MethodExtra.flags or
        ast.extra_data.items.len - extra <= ast_mod.MethodExtra.key or
        ast.extra_data.items.len - extra <= ast_mod.MethodExtra.body) return false;
    const flags = ast.extra_data.items[extra + ast_mod.MethodExtra.flags];
    if (flags != ast_mod.MethodFlags.is_async) return false;
    const key_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra + ast_mod.MethodExtra.key]));
    if (key_idx.isNone() or @backingInt(key_idx) >= ast.nodes.items.len) return false;
    if (!isRetainableAsyncObjectMethodKey(ast, semantic, key_idx)) return false;

    const owner_raw = parents.get(@backingInt(method_idx)) orelse return false;
    if (owner_raw >= ast.nodes.items.len or ast.nodes.items[owner_raw].tag != .object_expression) return false;
    const body_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra + ast_mod.MethodExtra.body]));
    if (body_idx.isNone() or @backingInt(body_idx) >= ast.nodes.items.len) return false;
    const body_nodes = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, body_idx) catch return false;
    defer ast.allocator.free(body_nodes);
    for (body_nodes) |raw_idx| {
        if (raw_idx >= ast.nodes.items.len) return false;
        if (ast.nodes.items[raw_idx].tag != .super_expression) continue;
        var current = raw_idx;
        var lexical_arrow_depth: usize = 0;
        var hops: usize = 0;
        while (current != @backingInt(method_idx) and hops < ast.nodes.items.len) : (hops += 1) {
            current = parents.get(current) orelse return false;
            if (current == @backingInt(method_idx)) break;
            switch (ast.nodes.items[current].tag) {
                .function_declaration,
                .function_expression,
                .function,
                .class_declaration,
                .class_expression,
                .method_definition,
                => return false,
                .arrow_function_expression => {
                    lexical_arrow_depth += 1;
                    const nested_arrow = ast.nodes.items[current];
                    const arrow_extra = nested_arrow.data.extra;
                    if (lexical_arrow_depth > 1 or arrow_extra > ast.extra_data.items.len or
                        ast.extra_data.items.len - arrow_extra <= ast_mod.ArrowExtra.flags) return false;
                    // A single async arrow is admitted only when its own
                    // state-machine preflight retains the exact method home
                    // graph; deeper arrow scopes remain outside this gate.
                },
                else => {},
            }
        }
        if (current != @backingInt(method_idx)) return false;
    }
    return true;
}

// Super lowering may add runtime helpers. Suppress the reanalysis fallback
// only when every reachable use resolves to an owner with an exact retained
// home-object graph.
fn allSuperUsesBelongToRetainedOwners(
    ast: *const ast_mod.Ast,
    reachable_nodes: []const u32,
    retained_async_functions: *const std.AutoHashMapUnmanaged(u32, void),
    retained_sync_super_methods: *const std.AutoHashMapUnmanaged(u32, void),
    parents: *const std.AutoHashMapUnmanaged(u32, u32),
) bool {
    var has_super = false;
    for (reachable_nodes) |raw_idx| {
        if (raw_idx >= ast.nodes.items.len) return false;
        if (ast.nodes.items[raw_idx].tag != .super_expression) continue;
        has_super = true;
        var current = raw_idx;
        var hops: usize = 0;
        var found_method = false;
        while (hops < ast.nodes.items.len) : (hops += 1) {
            current = parents.get(current) orelse return false;
            if (current >= ast.nodes.items.len) return false;
            switch (ast.nodes.items[current].tag) {
                .arrow_function_expression => {
                    const extra = ast.nodes.items[current].data.extra;
                    if (extra > ast.extra_data.items.len or
                        ast.extra_data.items.len - extra <= ast_mod.ArrowExtra.flags) return false;
                    const flags = ast.extra_data.items[extra + ast_mod.ArrowExtra.flags];
                    if ((flags & ast_mod.ArrowFlags.is_async) != 0 and
                        !retained_async_functions.contains(current)) return false;
                },
                .method_definition => {
                    const is_retained_async_method = retained_async_functions.contains(current);
                    const is_retained_sync_method = retained_sync_super_methods.contains(current);
                    if (!is_retained_async_method and !is_retained_sync_method) return false;
                    found_method = true;
                    break;
                },
                .function_declaration,
                .function_expression,
                .function,
                .class_declaration,
                .class_expression,
                => return false,
                else => {},
            }
        }
        if (!found_method) return false;
    }
    return has_super;
}

/// Async arrows keep their source arrow scope while the lowered generator is
/// nested inside it. Lexical `this`, `arguments`, and `new.target` references
/// are safe once the transformer has represented them with exact capture
/// bindings. `super` is lowered through the enclosing method's exact super
/// base and tracked helper references before the body enters the generator.
fn isRetainableAsyncArrowNode(
    ast: *const ast_mod.Ast,
    arrow_idx: ast_mod.NodeIndex,
    options: TransformOptions,
) bool {
    if (!options.unsupported.async_await or options.unsupported.generator or
        arrow_idx.isNone() or @backingInt(arrow_idx) >= ast.nodes.items.len) return false;
    const node = ast.getNode(arrow_idx);
    if (node.tag != .arrow_function_expression) return false;
    const flags_at = node.data.extra + ast_mod.ArrowExtra.flags;
    if (flags_at >= ast.extra_data.items.len or
        (ast.extra_data.items[flags_at] & ast_mod.ArrowFlags.is_async) == 0) return false;

    const reachable = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, arrow_idx) catch return false;
    defer ast.allocator.free(reachable);
    for (reachable) |raw_idx| {
        if (raw_idx >= ast.nodes.items.len) return false;
        // The async-arrow transform lowers this lexical operation while the
        // source method/object home-object context is active. The emitted
        // generator therefore contains no raw `super` syntax and all helper
        // references are already part of the edited graph.
    }
    return true;
}

const Es5AsyncArrowLexicalCaptures = struct {
    this_value: bool = false,
    arguments: bool = false,
    new_target: bool = false,
    super_value: bool = false,
};

fn es5AsyncArrowLexicalCaptures(
    ast: *const ast_mod.Ast,
    arrow_idx: ast_mod.NodeIndex,
) ?Es5AsyncArrowLexicalCaptures {
    if (arrow_idx.isNone() or @backingInt(arrow_idx) >= ast.nodes.items.len) return null;
    const arrow = ast.getNode(arrow_idx);
    if (arrow.tag != .arrow_function_expression) return null;
    const extra = arrow.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= ast_mod.ArrowExtra.body)
        return null;

    var stack: std.ArrayList(ast_mod.NodeIndex) = .empty;
    defer stack.deinit(ast.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(ast.allocator);
    for ([_]ast_mod.NodeIndex{
        @fromBackingInt(@intCast(ast.extra_data.items[extra + ast_mod.ArrowExtra.params])),
        @fromBackingInt(@intCast(ast.extra_data.items[extra + ast_mod.ArrowExtra.body])),
    }) |root| {
        if (!root.isNone()) stack.append(ast.allocator, root) catch return null;
    }

    var captures: Es5AsyncArrowLexicalCaptures = .{};
    while (stack.pop()) |idx| {
        if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) return null;
        const raw_idx = @backingInt(idx);
        if (seen.contains(raw_idx)) continue;
        seen.put(ast.allocator, raw_idx, {}) catch return null;
        const node = ast.getNode(idx);
        switch (node.tag) {
            .this_expression => captures.this_value = true,
            .super_expression => captures.super_value = true,
            .identifier_reference, .assignment_target_identifier => {
                if (std.mem.eql(u8, ast.getText(node.span), "arguments")) captures.arguments = true;
            },
            .meta_property => {
                if (node.data.none == 1) captures.new_target = true;
            },
            else => {},
        }
        switch (node.tag) {
            .function_declaration,
            .function_expression,
            .function,
            .class_declaration,
            .class_expression,
            .method_definition,
            => continue,
            else => {},
        }
        var children = ast_walk.children(ast, node);
        while (children.next()) |child| {
            if (!child.isNone()) stack.append(ast.allocator, child) catch return null;
        }
    }
    return captures;
}

// Object async methods can keep method-body super uses beside super captures
// in one audited async-arrow owner. Class-method gates remain arrow-only or
// direct-body-only so their separate home-object paths do not get combined.
fn methodSuperUsesInAsyncArrowScopesOrDirectBody(
    ast: *const ast_mod.Ast,
    method: ast_mod.Node,
    allow_direct_method_body: bool,
) bool {
    if (method.tag != .method_definition) return false;
    const extra = method.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= ast_mod.MethodExtra.body)
        return false;

    const Work = struct {
        node: ast_mod.NodeIndex,
        in_method_body: bool,
        inside_arrow: bool = false,
        inside_async_arrow: bool = false,
    };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(ast.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(ast.allocator);
    const params_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra + ast_mod.MethodExtra.params]));
    const body_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra + ast_mod.MethodExtra.body]));
    if (!params_idx.isNone()) stack.append(ast.allocator, .{
        .node = params_idx,
        .in_method_body = false,
    }) catch return false;
    if (!body_idx.isNone()) stack.append(ast.allocator, .{
        .node = body_idx,
        .in_method_body = true,
    }) catch return false;

    var found_async_arrow_super = false;
    while (stack.pop()) |work| {
        if (work.node.isNone() or @backingInt(work.node) >= ast.nodes.items.len) return false;
        const raw_idx = @backingInt(work.node);
        if (seen.contains(raw_idx)) continue;
        seen.put(ast.allocator, raw_idx, {}) catch return false;
        const node = ast.getNode(work.node);
        if (node.tag == .super_expression) {
            if (!work.in_method_body) return false;
            if (work.inside_async_arrow) {
                found_async_arrow_super = true;
                continue;
            }
            if (!allow_direct_method_body or !work.in_method_body or work.inside_arrow) return false;
            continue;
        }
        switch (node.tag) {
            .function_declaration,
            .function_expression,
            .function,
            .class_declaration,
            .class_expression,
            .method_definition,
            => continue,
            else => {},
        }
        const is_arrow = node.tag == .arrow_function_expression;
        if (is_arrow and (node.data.extra > ast.extra_data.items.len or
            ast.extra_data.items.len - node.data.extra <= ast_mod.ArrowExtra.flags)) return false;
        const is_async_arrow = is_arrow and
            (ast.extra_data.items[node.data.extra + ast_mod.ArrowExtra.flags] & ast_mod.ArrowFlags.is_async) != 0;
        const inside_async_arrow = work.inside_async_arrow or is_async_arrow;
        var children = ast_walk.children(ast, node);
        while (children.next()) |child| {
            if (!child.isNone()) stack.append(ast.allocator, .{
                .node = child,
                .in_method_body = work.in_method_body,
                .inside_arrow = work.inside_arrow or is_arrow,
                .inside_async_arrow = inside_async_arrow,
            }) catch return false;
        }
    }
    return found_async_arrow_super;
}

fn isRetainableEs5AsyncArrowSuper(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    arrow_idx: ast_mod.NodeIndex,
    options: TransformOptions,
    parents: *const std.AutoHashMapUnmanaged(u32, u32),
) bool {
    if (!options.unsupported.async_await or !options.unsupported.generator or
        arrow_idx.isNone() or @backingInt(arrow_idx) >= ast.nodes.items.len) return false;
    const arrow = ast.getNode(arrow_idx);
    const captures = es5AsyncArrowLexicalCaptures(ast, arrow_idx) orelse return false;
    if (arrow.tag != .arrow_function_expression or !captures.super_value) return false;
    const extra = arrow.data.extra;
    if (extra > ast.extra_data.items.len or
        ast.extra_data.items.len - extra <= ast_mod.ArrowExtra.params or
        ast.extra_data.items.len - extra <= ast_mod.ArrowExtra.flags or
        (ast.extra_data.items[extra + ast_mod.ArrowExtra.flags] & ast_mod.ArrowFlags.is_async) == 0) return false;
    var current = parents.get(@backingInt(arrow_idx)) orelse return false;
    var hops: usize = 0;
    while (hops < ast.nodes.items.len) : (hops += 1) {
        if (current >= ast.nodes.items.len) return false;
        const node = ast.nodes.items[current];
        if (node.tag == .method_definition) {
            const method_extra = node.data.extra;
            if (method_extra > ast.extra_data.items.len or
                ast.extra_data.items.len - method_extra <= ast_mod.MethodExtra.flags or
                ast.extra_data.items.len - method_extra <= ast_mod.MethodExtra.key or
                ast.extra_data.items.len - method_extra <= ast_mod.MethodExtra.body) return false;
            const flags = ast.extra_data.items[method_extra + ast_mod.MethodExtra.flags];
            const method_owner_raw = parents.get(current) orelse return false;
            if (method_owner_raw >= ast.nodes.items.len) return false;
            const method_owner = ast.nodes.items[method_owner_raw];
            const is_async_object_method = flags == ast_mod.MethodFlags.is_async and
                method_owner.tag == .object_expression;
            const is_async_class_method =
                (flags == ast_mod.MethodFlags.is_async or
                    flags == (ast_mod.MethodFlags.is_async | ast_mod.MethodFlags.is_static)) and
                method_owner.tag == .class_body;
            if (flags != 0 and flags != ast_mod.MethodFlags.is_static and
                !is_async_object_method and !is_async_class_method) return false;
            const key_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[method_extra + ast_mod.MethodExtra.key]));
            if (key_idx.isNone() or @backingInt(key_idx) >= ast.nodes.items.len) return false;
            const key = ast.getNode(key_idx);
            if (method_owner.tag == .object_expression) {
                if (!isRetainableAsyncObjectMethodKey(ast, semantic, key_idx)) return false;
            } else if (key.tag != .identifier_reference) return false;
            if (method_extra > ast.extra_data.items.len or
                ast.extra_data.items.len - method_extra <= ast_mod.MethodExtra.body) return false;
            const body_raw = ast.extra_data.items[method_extra + ast_mod.MethodExtra.body];
            if (body_raw >= ast.nodes.items.len) return false;
            var child_raw = @backingInt(arrow_idx);
            var inside_method_body = false;
            while (child_raw != current) {
                child_raw = parents.get(child_raw) orelse return false;
                if (child_raw == body_raw) {
                    inside_method_body = true;
                    break;
                }
            }
            if (!inside_method_body) return false;
            if (method_owner.tag == .object_expression) {
                if (is_async_object_method and !isRetainableEs5AsyncObjectMethodNode(
                    ast,
                    semantic,
                    @fromBackingInt(@intCast(current)),
                    options,
                    parents,
                )) return false;
                return methodSuperUsesInAsyncArrowScopesOrDirectBody(ast, node, true);
            }
            if (method_owner.tag != .class_body or std.mem.eql(u8, ast.getText(key.span), "constructor"))
                return false;
            if (flags == 0 or flags == ast_mod.MethodFlags.is_static) {
                // Parameter defaults run before a synchronous method's async
                // state-machine body is entered. Keep those home-object reads
                // on reanalysis. Async class methods have a separate audited
                // parameter-default gate.
                const params_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(
                    ast.extra_data.items[extra + ast_mod.ArrowExtra.params],
                ));
                if (!params_idx.isNone()) {
                    if (@backingInt(params_idx) >= ast.nodes.items.len) return false;
                    const parameter_nodes = ast_walk.collectReachableNodeIndicesFrom(
                        ast.allocator,
                        ast,
                        params_idx,
                    ) catch return false;
                    defer ast.allocator.free(parameter_nodes);
                    for (parameter_nodes) |raw_idx| {
                        if (raw_idx >= ast.nodes.items.len or
                            ast.nodes.items[raw_idx].tag == .super_expression) return false;
                    }
                }
            }
            const class_raw = parents.get(method_owner_raw) orelse return false;
            if (class_raw >= ast.nodes.items.len) return false;
            const class = ast.nodes.items[class_raw];
            return (class.tag == .class_declaration or class.tag == .class_expression) and
                methodSuperUsesInAsyncArrowScopesOrDirectBody(ast, node, false);
        }
        switch (node.tag) {
            .function_declaration,
            .function_expression,
            .function,
            .class_declaration,
            .class_expression,
            .class_body,
            => return false,
            else => {},
        }
        current = parents.get(current) orelse return false;
    }
    return false;
}

fn isRetainableEs5AsyncArrowStateMachine(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    arrow_idx: ast_mod.NodeIndex,
    options: TransformOptions,
    parents: *const std.AutoHashMapUnmanaged(u32, u32),
) bool {
    if (!options.unsupported.async_await or !options.unsupported.generator or
        arrow_idx.isNone() or @backingInt(arrow_idx) >= ast.nodes.items.len) return false;
    const arrow = ast.getNode(arrow_idx);
    if (arrow.tag != .arrow_function_expression) return false;
    const flags_at = arrow.data.extra + ast_mod.ArrowExtra.flags;
    if (flags_at >= ast.extra_data.items.len or
        (ast.extra_data.items[flags_at] & ast_mod.ArrowFlags.is_async) == 0) return false;

    const captures = es5AsyncArrowLexicalCaptures(ast, arrow_idx) orelse return false;
    if (captures.super_value)
        return isRetainableEs5AsyncArrowSuper(ast, semantic, arrow_idx, options, parents);

    // Parameter initializers run before the async arrow's body wrapper exists.
    var current = parents.get(@backingInt(arrow_idx)) orelse return false;
    var hops: usize = 0;
    while (hops < ast.nodes.items.len) : (hops += 1) {
        if (current >= ast.nodes.items.len) return false;
        const ancestor = ast.nodes.items[current];
        if (ancestor.tag == .formal_parameter) return false;
        if (ancestor.tag == .program) return true;
        current = parents.get(current) orelse return false;
    }
    return false;
}

fn awaitBelongsToRetainableAsyncFunction(
    ast: *const ast_mod.Ast,
    parents: *const std.AutoHashMapUnmanaged(u32, u32),
    retained_async_functions: *const std.AutoHashMapUnmanaged(u32, void),
    await_node: u32,
) bool {
    var current = parents.get(await_node) orelse return false;
    var hops: usize = 0;
    while (hops < ast.nodes.items.len) : (hops += 1) {
        if (current >= ast.nodes.items.len) return false;
        const node = ast.nodes.items[current];
        switch (node.tag) {
            .function_declaration,
            .function_expression,
            .function,
            .arrow_function_expression,
            .method_definition,
            => return retained_async_functions.contains(current),
            else => current = parents.get(current) orelse return false,
        }
    }
    return false;
}

/// Arrow lowering edits the existing graph and creates only output function
/// scopes plus explicitly tracked captures. Native `await` and `yield` add no
/// binding or scope edges. Tagged-template lowering registers its cache
/// functions, data bindings, and references with exact identities. Keep these
/// paths only for the audited syntax subset. Ordinary async functions retain
/// their graph when they lower to either a native generator wrapper or an ES5
/// state machine. Async arrows also retain their graph with audited lexical
/// captures when their exact bindings and references are registered. When
/// `super` is present, admit it only when every use belongs to a plain method
/// or an audited async class/object method with a retained home-object graph.
/// Async-arrow captures must pass their own preflight.
/// Direct eval and parameter initializer arrows remain outside this subset.
fn canRetainGraphForAuditedSyntaxSubset(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    options: TransformOptions,
    allow_es5_async_method_super_get: *bool,
    allow_es5_async_method_super_set: *bool,
) bool {
    allow_es5_async_method_super_get.* = false;
    allow_es5_async_method_super_set.* = false;
    // Cover-grammar parsing may leave speculative nodes in the arena that are
    // not part of the program. Only reachable syntax can affect this lowering.
    if (ast.nodes.items.len == 0) return false;
    const root_idx = ast.transformed_root orelse @as(
        ast_mod.NodeIndex,
        @fromBackingInt(@intCast(@as(u32, @intCast(ast.nodes.items.len - 1)))),
    );
    if (root_idx.isNone() or @backingInt(root_idx) >= ast.nodes.items.len or
        ast.getNode(root_idx).tag != .program) return false;
    const reachable_nodes = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, root_idx) catch return false;
    defer ast.allocator.free(reachable_nodes);
    var top_level_statements = ast_walk.topLevelStatementMask(ast) catch return false;
    defer top_level_statements.deinit();
    var retained_static_field_optional_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer retained_static_field_optional_nodes.deinit(ast.allocator);
    if (options.unsupported.optional_chaining and
        !collectRetainableStaticFieldOptionalInvocations(
            allocator,
            ast,
            semantic,
            reachable_nodes,
            &retained_static_field_optional_nodes,
        )) return false;

    // ES5 for-in/of block-scoping lowering edits the original loop-head
    // SymbolIds and records generated loop/catch bindings in their output
    // scopes. Admit only lexical declarations that are direct iteration heads;
    // unrelated let/const still needs the full semantic resync path.
    var lowered_for_in_heads: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer lowered_for_in_heads.deinit(ast.allocator);
    var lowered_for_of_heads: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer lowered_for_of_heads.deinit(ast.allocator);
    var lowered_classic_for_heads: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer lowered_classic_for_heads.deinit(ast.allocator);
    var source_parent_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer source_parent_map.deinit(ast.allocator);
    var source_parent_map_ready = false;
    var retained_async_functions: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer retained_async_functions.deinit(ast.allocator);
    var retained_sync_super_methods: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer retained_sync_super_methods.deinit(ast.allocator);
    if (options.unsupported.async_await) {
        for (reachable_nodes) |raw_idx| {
            const node = ast.nodes.items[raw_idx];
            const arrow_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw_idx));
            var retainable = false;
            if (options.unsupported.generator) {
                if (node.tag == .arrow_function_expression) {
                    const flags_at = node.data.extra + ast_mod.ArrowExtra.flags;
                    if (flags_at < ast.extra_data.items.len and
                        (ast.extra_data.items[flags_at] & ast_mod.ArrowFlags.is_async) != 0)
                    {
                        if (!source_parent_map_ready) {
                            if (!collectRetainedPreflightParents(
                                ast.allocator,
                                ast,
                                root_idx,
                                &source_parent_map,
                            )) return false;
                            source_parent_map_ready = true;
                        }
                        retainable = isRetainableEs5AsyncArrowStateMachine(
                            ast,
                            semantic,
                            arrow_idx,
                            options,
                            &source_parent_map,
                        );
                    }
                } else if (node.tag == .method_definition) {
                    const flags_at = node.data.extra + ast_mod.MethodExtra.flags;
                    if (flags_at >= ast.extra_data.items.len) return false;
                    // Only plain async object methods need the ancestor map
                    // for their state-machine/super preflight. Synchronous
                    // methods are checked by the syntax walk below; building
                    // the map for them can unnecessarily force unrelated
                    // syntax through full reanalysis.
                    if (ast.extra_data.items[flags_at] == ast_mod.MethodFlags.is_async) {
                        if (!source_parent_map_ready) {
                            if (!collectRetainedPreflightParents(
                                ast.allocator,
                                ast,
                                root_idx,
                                &source_parent_map,
                            )) return false;
                            source_parent_map_ready = true;
                        }
                        retainable = isRetainableEs5AsyncObjectMethodNode(
                            ast,
                            semantic,
                            arrow_idx,
                            options,
                            &source_parent_map,
                        );
                    }
                } else {
                    retainable = isRetainableAsyncFunctionNode(ast, node, options);
                }
            } else {
                retainable = isRetainableAsyncFunctionNode(ast, node, options) or
                    isRetainableAsyncArrowNode(ast, arrow_idx, options);
            }
            if (retainable) {
                retained_async_functions.put(ast.allocator, raw_idx, {}) catch return false;
            }
        }
    }
    if (options.unsupported.block_scoping) {
        for (reachable_nodes) |raw_idx| {
            const node = ast.nodes.items[raw_idx];
            if (node.tag == .for_statement) {
                const extra = node.data.extra;
                if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 4) return false;
                const initializer: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
                if (!initializer.isNone() and @backingInt(initializer) < ast.nodes.items.len and
                    ast.nodes.items[@backingInt(initializer)].tag == .variable_declaration and
                    ast.variableDeclarationKind(ast.nodes.items[@backingInt(initializer)]).isLexical())
                {
                    if (!isSafeRetainedLexicalForStatement(ast, semantic, node)) return false;
                    lowered_classic_for_heads.put(ast.allocator, @backingInt(initializer), {}) catch return false;
                }
            }
            if (node.tag != .for_in_statement and
                !(node.tag == .for_of_statement and options.unsupported.for_of)) continue;
            const head = node.data.ternary.a;
            if (head.isNone() or @backingInt(head) >= ast.nodes.items.len) return false;
            const head_node = ast.nodes.items[@backingInt(head)];
            if (head_node.tag == .variable_declaration and
                ast.variableDeclarationKind(head_node) != .@"var")
            {
                const head_raw = @backingInt(head);
                const lowered_heads = if (node.tag == .for_in_statement)
                    &lowered_for_in_heads
                else
                    &lowered_for_of_heads;
                if (lowered_heads.contains(head_raw)) return false;
                lowered_heads.put(ast.allocator, head_raw, {}) catch return false;
            }
        }
    }

    // ES5 destructuring declarations are lowered inside their existing `var`
    // scope. The destructuring visitor registers every generated temp and
    // helper reference in the edited graph. Keep loop heads out of this set:
    // their per-iteration ownership has a separate loop-lowering contract.
    var destructuring_loop_heads: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer destructuring_loop_heads.deinit(ast.allocator);
    for (reachable_nodes) |raw_idx| {
        const node = ast.nodes.items[raw_idx];
        if (node.tag != .for_in_statement and node.tag != .for_of_statement and
            node.tag != .for_await_of_statement) continue;
        const head = node.data.ternary.a;
        if (head.isNone() or @backingInt(head) >= ast.nodes.items.len) return false;
        if (ast.nodes.items[@backingInt(head)].tag == .variable_declaration) {
            destructuring_loop_heads.put(ast.allocator, @backingInt(head), {}) catch return false;
        }
    }

    var lowered_var_destructuring_declarators: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer lowered_var_destructuring_declarators.deinit(ast.allocator);
    var lowered_var_destructuring_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer lowered_var_destructuring_nodes.deinit(ast.allocator);
    var lowered_destructuring_assignment_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer lowered_destructuring_assignment_nodes.deinit(ast.allocator);
    var lowered_parameter_destructuring_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer lowered_parameter_destructuring_nodes.deinit(ast.allocator);
    if (options.unsupported.destructuring) {
        const extras = ast.extra_data.items;
        for (reachable_nodes) |raw_idx| {
            const declaration = ast.nodes.items[raw_idx];
            if (declaration.tag != .variable_declaration or
                ast.variableDeclarationKind(declaration) != .@"var" or
                destructuring_loop_heads.contains(raw_idx)) continue;
            const extra = declaration.data.extra;
            if (extra > extras.len or extras.len - extra <= 2) return false;
            const start = extras[extra + 1];
            const len = extras[extra + 2];
            if (start > extras.len or len > extras.len - start) return false;
            for (extras[start .. start + len]) |raw_declarator| {
                if (raw_declarator >= ast.nodes.items.len) return false;
                const declarator = ast.nodes.items[raw_declarator];
                if (declarator.tag != .variable_declarator) continue;
                const binding_extra = declarator.data.extra;
                if (binding_extra >= extras.len) return false;
                const binding_raw = extras[binding_extra];
                if (binding_raw >= ast.nodes.items.len) return false;
                const binding_tag = ast.nodes.items[binding_raw].tag;
                if (binding_tag != .array_pattern and binding_tag != .object_pattern) continue;

                lowered_var_destructuring_declarators.put(ast.allocator, raw_declarator, {}) catch return false;
                const pattern_nodes = ast_walk.collectReachableNodeIndicesFrom(
                    ast.allocator,
                    ast,
                    @fromBackingInt(@intCast(binding_raw)),
                ) catch return false;
                defer ast.allocator.free(pattern_nodes);
                for (pattern_nodes) |pattern_raw| {
                    lowered_var_destructuring_nodes.put(ast.allocator, pattern_raw, {}) catch return false;
                }
            }
        }

        for (reachable_nodes) |raw_idx| {
            const assignment = ast.nodes.items[raw_idx];
            if (assignment.tag != .assignment_expression or
                assignment.data.binary.flags != @backingInt(token_mod.Kind.eq)) continue;
            const target = assignment.data.binary.left;
            if (target.isNone() or @backingInt(target) >= ast.nodes.items.len) return false;
            const target_tag = ast.nodes.items[@backingInt(target)].tag;
            if (target_tag != .array_assignment_target and target_tag != .object_assignment_target) continue;
            const target_nodes = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, target) catch return false;
            defer ast.allocator.free(target_nodes);
            for (target_nodes) |target_raw| {
                lowered_destructuring_assignment_nodes.put(ast.allocator, target_raw, {}) catch return false;
            }
        }

        // Destructuring parameters without defaults/rest are lowered by the
        // parameter pass, which registers the replacement parameter and all
        // emitted reads/writes in the same edited graph. Keep default and rest
        // patterns on reanalysis: they also change parameter initialization
        // order and have separate target gates.
        for (reachable_nodes) |raw_idx| {
            const parameter = ast.nodes.items[raw_idx];
            if (parameter.tag != .formal_parameter) continue;
            const extra = parameter.data.extra;
            if (extra > extras.len or extras.len - extra <= ast_mod.FormalParameterExtra.default) return false;
            const pattern_raw = extras[extra + ast_mod.FormalParameterExtra.pattern];
            const default_raw = extras[extra + ast_mod.FormalParameterExtra.default];
            if (pattern_raw >= ast.nodes.items.len) return false;
            const default_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(default_raw));
            if (!default_idx.isNone() and @backingInt(default_idx) >= ast.nodes.items.len) return false;
            const pattern_tag = ast.nodes.items[pattern_raw].tag;
            if ((pattern_tag != .array_pattern and pattern_tag != .object_pattern) or
                !default_idx.isNone()) continue;
            const pattern_nodes = ast_walk.collectReachableNodeIndicesFrom(
                ast.allocator,
                ast,
                @fromBackingInt(@intCast(pattern_raw)),
            ) catch return false;
            defer ast.allocator.free(pattern_nodes);
            var simple_pattern = true;
            for (pattern_nodes) |pattern_raw_idx| {
                const child_tag = ast.nodes.items[pattern_raw_idx].tag;
                if (child_tag == .assignment_pattern or child_tag == .binding_rest_element or
                    child_tag == .rest_element)
                {
                    simple_pattern = false;
                    break;
                }
            }
            if (!simple_pattern) continue;
            for (pattern_nodes) |pattern_raw_idx| {
                lowered_parameter_destructuring_nodes.put(ast.allocator, pattern_raw_idx, {}) catch return false;
            }
        }

        // Untyped destructuring parameters are direct children of the
        // formal_parameters list rather than formal_parameter wrappers.
        for (reachable_nodes) |raw_idx| {
            const params = ast.nodes.items[raw_idx];
            if (params.tag != .formal_parameters) continue;
            const list = params.data.list;
            if (list.start > extras.len or list.len > extras.len - list.start) return false;
            for (extras[list.start .. list.start + list.len]) |parameter_raw| {
                if (parameter_raw >= ast.nodes.items.len) return false;
                const parameter_tag = ast.nodes.items[parameter_raw].tag;
                if (parameter_tag != .array_pattern and parameter_tag != .object_pattern) continue;
                const pattern_nodes = ast_walk.collectReachableNodeIndicesFrom(
                    ast.allocator,
                    ast,
                    @fromBackingInt(@intCast(parameter_raw)),
                ) catch return false;
                defer ast.allocator.free(pattern_nodes);
                var simple_pattern = true;
                for (pattern_nodes) |pattern_raw_idx| {
                    const child_tag = ast.nodes.items[pattern_raw_idx].tag;
                    if (child_tag == .assignment_pattern or child_tag == .binding_rest_element or
                        child_tag == .rest_element)
                    {
                        simple_pattern = false;
                        break;
                    }
                }
                if (!simple_pattern) continue;
                for (pattern_nodes) |pattern_raw_idx| {
                    lowered_parameter_destructuring_nodes.put(ast.allocator, pattern_raw_idx, {}) catch return false;
                }
            }
        }
    }

    // Plain computed data properties, synchronous object methods, async object
    // methods with static keys or safe source-bound key expressions, computed
    // accessors without `super`, and audited static class-field keys lower
    // through tracked temps and output scopes. Accessor `super` may add a
    // runtime helper module, so it stays on reanalysis. Generator methods and
    // other async keys stay gated out.
    const ComputedObjectKeyOwner = enum { data_property, method, accessor, static_class_field };
    const ComputedObjectKey = struct { node: ast_mod.NodeIndex, owner: ComputedObjectKeyOwner };
    var computed_object_keys: std.AutoHashMapUnmanaged(u32, ComputedObjectKeyOwner) = .empty;
    defer computed_object_keys.deinit(ast.allocator);
    if (options.unsupported.object_extensions) {
        for (reachable_nodes) |raw_idx| {
            const owner_node = ast.nodes.items[raw_idx];
            if (owner_node.tag == .property_definition) {
                const key_at = owner_node.data.extra + ast_mod.PropertyExtra.key;
                if (key_at >= ast.extra_data.items.len) return false;
                const key: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[key_at]));
                if (key.isNone() or @backingInt(key) >= ast.nodes.items.len or
                    ast.nodes.items[@backingInt(key)].tag != .computed_property_key or
                    !isRetainableSimpleStaticClassField(allocator, ast, semantic, owner_node)) continue;
                computed_object_keys.put(ast.allocator, @backingInt(key), .static_class_field) catch return false;
                continue;
            }
            if (owner_node.tag != .object_expression) continue;
            const members = owner_node.data.list;
            if (members.start > ast.extra_data.items.len or
                members.len > ast.extra_data.items.len - members.start) return false;
            for (ast.extra_data.items[members.start .. members.start + members.len]) |raw_member| {
                if (raw_member >= ast.nodes.items.len) return false;
                const member = ast.nodes.items[raw_member];
                const candidate: ?ComputedObjectKey = switch (member.tag) {
                    .object_property => .{
                        .node = member.data.binary.left,
                        .owner = .data_property,
                    },
                    .method_definition => blk: {
                        const method_extra = member.data.extra;
                        if (method_extra > ast.extra_data.items.len or
                            ast.extra_data.items.len - method_extra <= ast_mod.MethodExtra.flags) return false;
                        const flags = ast.extra_data.items[method_extra + ast_mod.MethodExtra.flags];
                        if ((flags & ast_mod.MethodFlags.is_generator) != 0) break :blk null;
                        const is_async = (flags & ast_mod.MethodFlags.is_async) != 0;
                        const key_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(
                            ast.extra_data.items[method_extra + ast_mod.MethodExtra.key],
                        ));
                        if (is_async and !isRetainableAsyncObjectMethodKey(ast, semantic, key_idx)) break :blk null;
                        const is_accessor = (flags & (ast_mod.MethodFlags.is_getter | ast_mod.MethodFlags.is_setter)) != 0;
                        break :blk .{
                            .node = @fromBackingInt(@intCast(ast.extra_data.items[method_extra + ast_mod.MethodExtra.key])),
                            .owner = if (is_accessor) .accessor else .method,
                        };
                    },
                    else => null,
                };
                const computed = candidate orelse continue;
                if (computed.node.isNone() or @backingInt(computed.node) >= ast.nodes.items.len) return false;
                if (ast.nodes.items[@backingInt(computed.node)].tag != .computed_property_key) continue;
                if (computed.owner == .accessor and methodHasSuperExpression(ast, member)) continue;
                computed_object_keys.put(ast.allocator, @backingInt(computed.node), computed.owner) catch return false;
            }
        }
    }

    // Object-super/class-method lowering keeps its separate shadow gate; the
    // exponentiation path below is tracked through explicit-global markers.
    var source_binds_object = false;
    for (semantic.symbols.items) |symbol| {
        const name = ast.getText(symbol.name);
        if (std.mem.eql(u8, name, "Object")) source_binds_object = true;
        if (source_binds_object) break;
    }
    var found_lowered_async_function = false;

    // Default-parameter lowering replaces only these literal assignment
    // patterns with exact reads/writes of the same parameter SymbolId. Admit
    // those nodes only when their owning retained class already passes the
    // complete retained-graph preflight. Cache the class decisions so the
    // node walk below does not repeat the full class-body check.
    var retained_simple_class_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer retained_simple_class_nodes.deinit(ast.allocator);
    var lowered_simple_constructor_default_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer lowered_simple_constructor_default_nodes.deinit(ast.allocator);
    var function_body_class_declarations: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer function_body_class_declarations.deinit(ast.allocator);
    var direct_var_class_expressions: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer direct_var_class_expressions.deinit(ast.allocator);
    if (options.unsupported.class) {
        if (!collectDirectFunctionBodyClassDeclarations(ast, reachable_nodes, &function_body_class_declarations) or
            !collectDirectVarClassExpressions(ast, reachable_nodes, &direct_var_class_expressions)) return false;
        for (reachable_nodes) |raw_idx| {
            const class_node = ast.nodes.items[raw_idx];
            if (class_node.tag != .class_declaration and class_node.tag != .class_expression) continue;
            var source_object_shadows_class = false;
            if (source_binds_object) {
                if (!source_parent_map_ready) {
                    source_parent_map_ready = true;
                    if (!collectRetainedPreflightParents(ast.allocator, ast, root_idx, &source_parent_map)) return false;
                }
                source_object_shadows_class = sourceBindingShadowsGeneratedGlobalAtNode(
                    ast,
                    semantic,
                    &source_parent_map,
                    @intCast(raw_idx),
                    "Object",
                );
            }
            if (!isRetainableGraphClass(
                allocator,
                ast,
                semantic,
                class_node,
                raw_idx,
                &top_level_statements,
                &function_body_class_declarations,
                &direct_var_class_expressions,
                source_object_shadows_class,
                options.unsupported.async_await and options.unsupported.generator,
                options.unsupported.async_await and options.unsupported.generator,
            )) continue;
            retained_simple_class_nodes.put(ast.allocator, raw_idx, {}) catch return false;
            if (!registerRetainableSyncClassSuperMethods(
                ast,
                class_node,
                &retained_sync_super_methods,
            )) return false;
            if (options.unsupported.async_await and options.unsupported.generator and
                !registerRetainableEs5AsyncClassMethods(ast, class_node, &retained_async_functions)) return false;
            if (options.unsupported.default_params and
                !collectSimpleConstructorDefaultParameterNodes(
                    ast,
                    class_node,
                    &lowered_simple_constructor_default_nodes,
                )) return false;
        }
    }

    var found_arrow = false;
    var found_native_await = false;
    var found_native_generator = false;
    var found_lowered_generator = false;
    var found_native_tagged_template = false;
    var found_lowered_tagged_template = false;
    var found_native_for_in = false;
    var found_lowered_for_in = false;
    var found_lowered_classic_for = false;
    var found_native_for_of = false;
    var found_lowered_for_of = false;
    var found_native_for_await = false;
    var found_lowered_for_await = false;
    var found_native_class = false;
    var found_lowered_simple_class = false;
    var found_lowered_simple_static_class_field = false;
    var found_native_destructuring = false;
    var found_lowered_var_destructuring = false;
    var found_lowered_destructuring_assignment = false;
    var found_lowered_parameter_destructuring = false;
    var found_lowered_array_spread = false;
    var found_lowered_exponentiation = false;
    var found_lowered_nullish_coalescing = false;
    var found_lowered_logical_assignment = false;
    var found_lowered_object_rest = false;
    var found_lowered_object_spread = false;
    var found_lowered_optional_catch_binding = false;
    var found_lowered_new_target = false;
    var found_safe_template_literal = false;
    var found_lowered_optional_chaining = false;
    var found_computed_object_data_key = false;
    var found_computed_object_method_key = false;
    var found_computed_object_accessor_key = false;
    var found_object_shorthand = false;
    var found_lowered_object_method = false;
    for (reachable_nodes) |raw_idx| {
        const node = ast.nodes.items[raw_idx];
        // Type erasure already edits the semantic graph through the same
        // transform-aware path; its nodes add no runtime scopes or bindings.
        if (isTypeErasureTag(node.tag)) continue;
        switch (node.tag) {
            .arrow_function_expression => {
                const flags_at = node.data.extra + ast_mod.ArrowExtra.flags;
                if (flags_at >= ast.extra_data.items.len) return false;
                const is_async = (ast.extra_data.items[flags_at] & ast_mod.ArrowFlags.is_async) != 0;
                if (is_async and options.unsupported.async_await) {
                    if (!retained_async_functions.contains(raw_idx)) return false;
                    found_lowered_async_function = true;
                }
                if (options.unsupported.arrow) found_arrow = true;
            },
            .function_declaration, .function_expression, .function => {
                const flags_at = node.data.extra + ast_mod.FunctionExtra.flags;
                if (flags_at >= ast.extra_data.items.len) return false;
                const flags = ast.extra_data.items[flags_at];
                const is_async = (flags & ast_mod.FunctionFlags.is_async) != 0;
                const is_generator = (flags & ast_mod.FunctionFlags.is_generator) != 0;
                if (is_generator and is_async) return false;
                if (is_generator and options.unsupported.generator) {
                    // The state-machine visitor binds its generated state and
                    // temp symbols into the edited graph. Async generators
                    // still use the conservative resync path above.
                    found_lowered_generator = true;
                }
                if (is_async and options.unsupported.async_await) {
                    if (!retained_async_functions.contains(raw_idx)) return false;
                    found_lowered_async_function = true;
                }
            },
            .variable_declaration => {
                const kind = ast.variableDeclarationKind(node);
                if (options.unsupported.using and kind.isUsing()) return false;
                if (options.unsupported.block_scoping and kind != .@"var" and
                    !lowered_for_in_heads.contains(raw_idx) and
                    !lowered_for_of_heads.contains(raw_idx) and
                    !lowered_classic_for_heads.contains(raw_idx)) return false;
            },
            .variable_declarator => {
                if (node.data.extra >= ast.extra_data.items.len) return false;
                const binding: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[node.data.extra]));
                if (binding.isNone() or @backingInt(binding) >= ast.nodes.items.len) return false;
                const binding_tag = ast.nodes.items[@backingInt(binding)].tag;
                if (binding_tag == .binding_identifier) continue;
                if (binding_tag != .array_pattern and binding_tag != .object_pattern) return false;
                if (options.unsupported.destructuring) {
                    if (lowered_var_destructuring_declarators.contains(raw_idx) and
                        lowered_var_destructuring_nodes.contains(@backingInt(binding)))
                    {
                        found_lowered_var_destructuring = true;
                    } else if (lowered_parameter_destructuring_nodes.contains(@backingInt(binding))) {
                        found_lowered_parameter_destructuring = true;
                    } else return false;
                }
            },
            .formal_parameter => {
                const extra = node.data.extra;
                if (extra + 2 >= ast.extra_data.items.len) return false;
                const pattern: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
                const default_value: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra + 2]));
                if (pattern.isNone() or @backingInt(pattern) >= ast.nodes.items.len or
                    (!default_value.isNone() and options.unsupported.default_params)) return false;
                const pattern_tag = ast.nodes.items[@backingInt(pattern)].tag;
                if (pattern_tag != .binding_identifier) {
                    if (pattern_tag != .array_pattern and pattern_tag != .object_pattern) return false;
                    if (options.unsupported.destructuring) {
                        if (lowered_parameter_destructuring_nodes.contains(@backingInt(pattern))) {
                            found_lowered_parameter_destructuring = true;
                        } else return false;
                    }
                    if (pattern_tag == .object_pattern and options.unsupported.object_spread and
                        ast.nodeListSplitRest(ast.nodes.items[@backingInt(pattern)].data.list).rest_operand != null)
                    {
                        found_lowered_object_rest = true;
                    } else {
                        found_native_destructuring = true;
                    }
                }
                if (!default_value.isNone()) found_native_destructuring = true;
            },
            .array_pattern, .array_assignment_target => {
                if (options.unsupported.destructuring) {
                    if (node.tag == .array_pattern and lowered_var_destructuring_nodes.contains(raw_idx)) {
                        found_lowered_var_destructuring = true;
                    } else if (node.tag == .array_pattern and lowered_parameter_destructuring_nodes.contains(raw_idx)) {
                        found_lowered_parameter_destructuring = true;
                    } else if (node.tag == .array_assignment_target and lowered_destructuring_assignment_nodes.contains(raw_idx)) {
                        found_lowered_destructuring_assignment = true;
                    } else return false;
                } else {
                    found_native_destructuring = true;
                }
            },
            .object_pattern, .object_assignment_target => {
                if (options.unsupported.destructuring) {
                    if (node.tag == .object_pattern and lowered_var_destructuring_nodes.contains(raw_idx)) {
                        found_lowered_var_destructuring = true;
                    } else if (node.tag == .object_pattern and lowered_parameter_destructuring_nodes.contains(raw_idx)) {
                        found_lowered_parameter_destructuring = true;
                    } else if (node.tag == .object_assignment_target and lowered_destructuring_assignment_nodes.contains(raw_idx)) {
                        found_lowered_destructuring_assignment = true;
                    } else return false;
                } else if (options.unsupported.object_spread and
                    ast.nodeListSplitRest(node.data.list).rest_operand != null)
                {
                    found_lowered_object_rest = true;
                } else {
                    found_native_destructuring = true;
                }
            },
            .assignment_pattern => {
                // Literal defaults in an admitted simple class constructor
                // lower to exact references to the existing parameter SID.
                // Other parameter defaults and nested binding defaults stay
                // on their independently gated paths.
                if (options.unsupported.default_params or options.unsupported.destructuring) {
                    if (lowered_simple_constructor_default_nodes.contains(raw_idx)) {
                        // The owning retained class already passed its body,
                        // parameter, and scope preflight above.
                    } else if (lowered_var_destructuring_nodes.contains(raw_idx)) {
                        found_lowered_var_destructuring = true;
                    } else return false;
                } else {
                    found_native_destructuring = true;
                }
            },
            .assignment_target_with_default => {
                if (options.unsupported.destructuring) {
                    if (!lowered_destructuring_assignment_nodes.contains(raw_idx)) return false;
                    found_lowered_destructuring_assignment = true;
                } else {
                    found_native_destructuring = true;
                }
            },
            .binding_rest_element, .assignment_target_rest => {
                if (options.unsupported.destructuring) {
                    if (node.tag == .binding_rest_element and lowered_var_destructuring_nodes.contains(raw_idx)) {
                        found_lowered_var_destructuring = true;
                    } else if (node.tag == .assignment_target_rest and lowered_destructuring_assignment_nodes.contains(raw_idx)) {
                        found_lowered_destructuring_assignment = true;
                    } else return false;
                } else if (!options.unsupported.object_spread) {
                    found_native_destructuring = true;
                }
            },
            .rest_element => {
                if ((options.unsupported.default_params or options.unsupported.destructuring) and
                    !lowered_var_destructuring_nodes.contains(raw_idx) and
                    !lowered_destructuring_assignment_nodes.contains(raw_idx)) return false;
                // This node is also used for object-pattern rest. When the
                // target lowers object rest, its owning pattern records the
                // exact graph transform; don't admit the module as native
                // destructuring solely because of the rest leaf.
                if (lowered_var_destructuring_nodes.contains(raw_idx)) {
                    found_lowered_var_destructuring = true;
                } else if (lowered_parameter_destructuring_nodes.contains(raw_idx)) {
                    found_lowered_parameter_destructuring = true;
                } else if (lowered_destructuring_assignment_nodes.contains(raw_idx)) {
                    found_lowered_destructuring_assignment = true;
                } else if (!options.unsupported.object_spread) {
                    found_native_destructuring = true;
                }
            },
            .elision => {
                if (lowered_var_destructuring_nodes.contains(raw_idx)) {
                    found_lowered_var_destructuring = true;
                } else if (lowered_parameter_destructuring_nodes.contains(raw_idx)) {
                    found_lowered_parameter_destructuring = true;
                } else if (lowered_destructuring_assignment_nodes.contains(raw_idx)) {
                    found_lowered_destructuring_assignment = true;
                } else return false;
            },
            .template_literal => {
                // Untagged templates lower to string concatenation while
                // preserving their source references. Tagged templates have
                // their own gate because downleveling creates helper/cache state.
                found_safe_template_literal = true;
            },
            .super_expression => {
                // Object-method lowering records the generated home-object
                // binding and reads in the edited semantic graph.
                if (options.unsupported.object_extensions and source_binds_object) return false;
            },
            .object_property => {
                // Shorthand lowering duplicates the key as property text and
                // preserves the original value reference's symbol identity.
                if (node.data.binary.right.isNone()) found_object_shorthand = true;
            },
            .assignment_expression => {
                const operator: token_mod.Kind = @fromBackingInt(@intCast(node.data.binary.flags));
                if (options.unsupported.exponentiation and operator == .star2_eq) {
                    // Ordinary member temps and direct super-property temps
                    // are registered by their respective semantic editors.
                    if (!isRetainableAssignmentTarget(ast, semantic, node.data.binary.left) and
                        !isRetainableDirectSuperPropertyAccess(ast, node.data.binary.left, true))
                        return false;
                    found_lowered_exponentiation = true;
                }
                if (options.unsupported.logical_assignment and
                    (operator == .question2_eq or operator == .pipe2_eq or operator == .amp2_eq))
                {
                    // Ordinary member temps and direct super-property temps are
                    // registered by their respective transform semantic editors.
                    if (!isRetainableAssignmentTarget(ast, semantic, node.data.binary.left) and
                        !isRetainableDirectSuperPropertyAccess(ast, node.data.binary.left, true))
                        return false;
                    found_lowered_logical_assignment = true;
                }
            },
            .binary_expression, .logical_expression => {
                const operator: token_mod.Kind = @fromBackingInt(@intCast(node.data.binary.flags));
                if (node.tag == .binary_expression and options.unsupported.exponentiation and
                    operator == .star2)
                {
                    // ES2016 lowering marks Math.pow as an explicit global.
                    // The linker reserves that spelling and renames only the
                    // source binding that would otherwise capture the call.
                    found_lowered_exponentiation = true;
                }
                if (node.tag == .logical_expression and options.unsupported.nullish_coalescing and
                    operator == .question2)
                {
                    // Keep composed optional/nullish lowering on the existing
                    // resync path until both operators share one exact gate.
                    if (ast_mod.spineHasOptionalChain(ast, node.data.binary.left)) return false;
                    // Nullish lowering either duplicates an exact identifier
                    // read or registers its generated temp references.
                    found_lowered_nullish_coalescing = true;
                }
            },
            .array_expression, .call_expression, .new_expression => {
                if (options.unsupported.optional_chaining and
                    ast_mod.spineHasOptionalChain(ast, @fromBackingInt(@intCast(raw_idx))))
                {
                    if (node.tag != .call_expression or
                        (!isRetainableOptionalCall(ast, semantic, @fromBackingInt(@intCast(raw_idx))) and
                            !retained_static_field_optional_nodes.contains(raw_idx)))
                        return false;
                    found_lowered_optional_chaining = true;
                }
                if (options.unsupported.spread and hasDirectSpreadElement(ast, node)) {
                    if (!hasOnlyRetainableSpreadOperands(ast, semantic, node)) return false;
                    found_lowered_array_spread = true;
                }
            },
            .static_member_expression, .computed_member_expression => {
                if (options.unsupported.optional_chaining and
                    ast_mod.spineHasOptionalChain(ast, @fromBackingInt(@intCast(raw_idx))))
                {
                    // Optional member lowering evaluates this property once
                    // inside the null-checked branch. Audited ordinary member
                    // and call tails can follow; optional calls retain resync.
                    if (!isRetainableOptionalChainMemberAccess(ast, semantic, @fromBackingInt(@intCast(raw_idx))) and
                        !retained_static_field_optional_nodes.contains(raw_idx))
                        return false;
                    found_lowered_optional_chaining = true;
                }
            },
            .object_expression => {
                if (hasDirectSpreadElement(ast, node)) {
                    if (options.unsupported.object_spread) {
                        // Lowering emits Object.assign. Only a source Object
                        // binding visible from this expression can shadow it;
                        // unrelated nested bindings do not require reanalysis.
                        if (source_binds_object) {
                            if (!source_parent_map_ready) {
                                source_parent_map_ready = true;
                                if (!collectRetainedPreflightParents(ast.allocator, ast, root_idx, &source_parent_map)) return false;
                            }
                            if (sourceBindingShadowsGeneratedGlobalAtNode(
                                ast,
                                semantic,
                                &source_parent_map,
                                @intCast(raw_idx),
                                "Object",
                            )) return false;
                        }
                        found_lowered_object_spread = true;
                    } else if (options.unsupported.spread) {
                        return false;
                    }
                }
            },
            .computed_property_key => {
                // Computed data properties and synchronous methods have exact
                // generated-temp and output-function-scope tracking. Other
                // computed-key owners remain on semantic reanalysis.
                if (options.unsupported.object_extensions) {
                    if (lowered_var_destructuring_nodes.contains(raw_idx)) {
                        found_lowered_var_destructuring = true;
                    } else if (lowered_parameter_destructuring_nodes.contains(raw_idx)) {
                        found_lowered_parameter_destructuring = true;
                    } else if (lowered_destructuring_assignment_nodes.contains(raw_idx)) {
                        found_lowered_destructuring_assignment = true;
                    } else switch (computed_object_keys.get(raw_idx) orelse return false) {
                        .data_property => found_computed_object_data_key = true,
                        .method => found_computed_object_method_key = true,
                        .accessor => {
                            // Accessor lowering emits an explicit global Object.defineProperty call.
                            // A source binding named Object would shadow that generated global.
                            if (source_binds_object) return false;
                            found_computed_object_accessor_key = true;
                        },
                        .static_class_field => found_lowered_simple_static_class_field = true,
                    }
                }
            },
            .await_expression => {
                if (options.unsupported.async_await) {
                    if (!source_parent_map_ready) {
                        source_parent_map_ready = true;
                        if (!collectRetainedPreflightParents(ast.allocator, ast, root_idx, &source_parent_map)) return false;
                    }
                    if (!awaitBelongsToRetainableAsyncFunction(
                        ast,
                        &source_parent_map,
                        &retained_async_functions,
                        @intCast(raw_idx),
                    )) return false;
                    found_lowered_async_function = true;
                } else {
                    found_native_await = true;
                }
            },
            .yield_expression => {
                if (options.unsupported.generator) {
                    found_lowered_generator = true;
                } else {
                    found_native_generator = true;
                }
            },
            .tagged_template_expression => {
                if (options.unsupported.template_literal) {
                    // The ES2015 lowering creates a cache function plus its
                    // function-local data binding. The transformer registers
                    // both output scopes, exact binding SymbolIds, and every
                    // cache/data reference, so this edit can keep the graph.
                    found_lowered_tagged_template = true;
                } else {
                    found_native_tagged_template = true;
                }
            },
            .for_of_statement => {
                if (options.unsupported.for_of) {
                    found_lowered_for_of = true;
                } else {
                    found_native_for_of = true;
                }
            },
            .for_in_statement => {
                const head = node.data.ternary.a;
                if (!head.isNone() and lowered_for_in_heads.contains(@backingInt(head))) {
                    found_lowered_for_in = true;
                } else {
                    found_native_for_in = true;
                }
            },
            .for_statement => {
                const extra = node.data.extra;
                if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 4) return false;
                const initializer: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
                if (!initializer.isNone() and lowered_classic_for_heads.contains(@backingInt(initializer)))
                    found_lowered_classic_for = true;
            },
            .for_await_of_statement => {
                if (options.unsupported.needsForAwaitOfDownlevel()) {
                    // The ES2017 path lowers only the loop. Keep async/await
                    // native so rewriteForAwait's generated temps, catch
                    // binding, and moved iteration scope stay in one edited
                    // semantic graph. Older targets also lower the enclosing
                    // async function and must use the full reanalysis path.
                    if (options.unsupported.async_await or options.unsupported.generator) return false;
                    found_lowered_for_await = true;
                } else {
                    found_native_for_await = true;
                }
            },
            .class_declaration, .class_expression => {
                if (options.unsupported.class) {
                    if (!retained_simple_class_nodes.contains(raw_idx)) return false;
                    found_lowered_simple_class = true;
                } else {
                    found_native_class = true;
                }
            },
            .property_definition => {
                const key_at = node.data.extra + ast_mod.PropertyExtra.key;
                if (key_at >= ast.extra_data.items.len) return false;
                const key: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[key_at]));
                if (key.isNone() or @backingInt(key) >= ast.nodes.items.len) return false;
                if (ast.nodes.items[@backingInt(key)].tag == .private_identifier) {
                    if (options.unsupported.class_private_field) return false;
                } else if (options.unsupported.class_field or options.unsupported.class) {
                    if (!isRetainableSimpleStaticClassField(allocator, ast, semantic, node)) return false;
                    found_lowered_simple_static_class_field = true;
                }
            },
            .private_field_expression, .private_identifier => {
                // The access node alone does not distinguish a private field
                // from a private method value. Keep it only when both native
                // forms are supported; declaration nodes receive the more
                // precise feature check above.
                if (options.unsupported.class_private_field or options.unsupported.class_private_method) return false;
            },
            .static_block => {
                if (options.unsupported.class_static_block) return false;
            },
            .meta_property => {
                // `lowerNewTarget` records its generated expression in the
                // edited graph: named-function references reuse the source
                // function SymbolId, while arrow lexical captures bind their
                // synthetic references to the generated output scope. Keep
                // this syntax on the retained graph so those exact identities
                // survive linking without a semantic rescan.
                if (node.data.none == 1 and options.unsupported.new_target) {
                    found_lowered_new_target = true;
                }
            },
            .method_definition => {
                const key_at = node.data.extra + ast_mod.MethodExtra.key;
                if (key_at >= ast.extra_data.items.len) return false;
                const key: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[key_at]));
                if (key.isNone() or @backingInt(key) >= ast.nodes.items.len) return false;
                if (ast.nodes.items[@backingInt(key)].tag == .private_identifier and
                    options.unsupported.class_private_method) return false;
                const flags_at = node.data.extra + ast_mod.MethodExtra.flags;
                if (flags_at >= ast.extra_data.items.len) return false;
                const flags = ast.extra_data.items[flags_at];
                const is_async = (flags & ast_mod.MethodFlags.is_async) != 0;
                const is_generator = (flags & ast_mod.MethodFlags.is_generator) != 0;
                if ((is_async and is_generator and options.unsupported.async_generator) or
                    (is_async and options.unsupported.async_await and
                        !retained_async_functions.contains(raw_idx)) or
                    (is_generator and options.unsupported.generator)) return false;
                if (is_async and options.unsupported.async_await) found_lowered_async_function = true;
                const is_accessor = (flags & (ast_mod.MethodFlags.is_getter | ast_mod.MethodFlags.is_setter)) != 0;
                if (options.unsupported.object_extensions and !is_accessor) {
                    // The object-method lowering reuses this method's function
                    // scope for the generated function expression. Computed
                    // keys are gated above, while `super` requires new home
                    // object state and is rejected separately.
                    found_lowered_object_method = true;
                }
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
            .binding_property,
            .assignment_target_property_identifier,
            .assignment_target_property_property,
            .class_body,
            .conditional_expression,
            .template_element,
            .unary_expression,
            .update_expression,
            // Parent-specific checks above admit only audited array-literal
            // spread lowering. Bound identifier operands use an exact helper
            // reference; other downlevel spread stays on semantic reanalysis.
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
            // JSX lowering rewrites each tag to a call while preserving
            // source tag references through exact SymbolIds. The lowerer also
            // registers classic factory reads and automatic runtime imports
            // in the edited graph, so these source-only JSX nodes add no
            // untracked scope or binding edges when JSX is actually lowered.
            .jsx_element,
            .jsx_opening_element,
            .jsx_closing_element,
            .jsx_fragment,
            .jsx_opening_fragment,
            .jsx_closing_fragment,
            .jsx_attribute,
            .jsx_expression_container,
            .jsx_empty_expression,
            .jsx_text,
            .jsx_namespaced_name,
            .jsx_member_expression,
            .jsx_identifier,
            => {
                if (!options.jsx_transform) return false;
            },
            .jsx_spread_attribute => {
                if (!options.jsx_transform) return false;
                if (options.unsupported.object_spread) {
                    // JSX lowering materializes Object.assign after this
                    // source-graph preflight. Only a source Object binding
                    // visible from this spread can shadow it; unrelated
                    // nested bindings do not require reanalysis.
                    if (source_binds_object) {
                        if (!source_parent_map_ready) {
                            source_parent_map_ready = true;
                            if (!collectRetainedPreflightParents(ast.allocator, ast, root_idx, &source_parent_map)) return false;
                        }
                        if (sourceBindingShadowsGeneratedGlobalAtNode(
                            ast,
                            semantic,
                            &source_parent_map,
                            @intCast(raw_idx),
                            "Object",
                        )) return false;
                    }
                    found_lowered_object_spread = true;
                }
            },
            .jsx_spread_child => {
                // The JSX child becomes a generated spread_element. Its
                // downlevel helper and emitted array/call shape are not part
                // of this source-node allowlist.
                if (!options.jsx_transform or options.unsupported.spread) return false;
            },
            else => return false,
        }
        if (node.tag == .catch_clause and node.data.binary.left.isNone() and
            options.unsupported.optional_catch_binding)
        {
            // ES2019 lowering inserts one unused catch binding in the existing
            // catch scope and registers its exact synthetic SymbolId. No source
            // references or additional scope edges are introduced.
            found_lowered_optional_catch_binding = true;
        }
    }
    const safe_graph = found_arrow or found_native_await or found_native_generator or found_lowered_generator or
        found_lowered_async_function or
        found_native_tagged_template or found_lowered_tagged_template or
        found_native_for_in or found_lowered_for_in or found_lowered_classic_for or
        found_native_for_of or found_lowered_for_of or
        found_native_for_await or found_lowered_for_await or found_native_class or found_lowered_simple_class or
        found_lowered_simple_static_class_field or
        found_native_destructuring or
        found_lowered_var_destructuring or found_lowered_destructuring_assignment or found_lowered_parameter_destructuring or
        found_safe_template_literal or found_lowered_optional_chaining or found_object_shorthand or found_lowered_object_method or
        found_computed_object_data_key or found_computed_object_method_key or found_computed_object_accessor_key or
        found_lowered_array_spread or found_lowered_exponentiation or found_lowered_nullish_coalescing or
        found_lowered_logical_assignment or found_lowered_object_rest or found_lowered_object_spread or
        found_lowered_optional_catch_binding or found_lowered_new_target;
    if (safe_graph) {
        const has_super_use = for (reachable_nodes) |raw_idx| {
            if (raw_idx >= ast.nodes.items.len) return false;
            if (ast.nodes.items[raw_idx].tag == .super_expression) break true;
        } else false;
        if (has_super_use) {
            if (!source_parent_map_ready) {
                if (!collectRetainedPreflightParents(ast.allocator, ast, root_idx, &source_parent_map)) return false;
                source_parent_map_ready = true;
            }
            const retained_super_uses = allSuperUsesBelongToRetainedOwners(
                ast,
                reachable_nodes,
                &retained_async_functions,
                &retained_sync_super_methods,
                &source_parent_map,
            );
            allow_es5_async_method_super_get.* = retained_super_uses;
            allow_es5_async_method_super_set.* = retained_super_uses;
        }
    }
    return safe_graph;
}

/// A retained prepass graph may absorb imports introduced by audited generator,
/// iterator, array-spread, destructuring, tagged-template, inferred class-name,
/// bounded class lowering, and ES5 async class/object-method `super` property
/// reads/writes.
/// Any other runtime helper can indicate an independently lowered construct,
/// so keep that module on semantic resync.
/// `__extends` and `__callSuper` are admitted only when the retained-graph
/// preflight proved every lowered class safe.
fn hasReachableDerivedClass(ast: *const ast_mod.Ast) bool {
    if (ast.nodes.items.len == 0) return false;
    const root_idx = ast.transformed_root orelse @as(
        ast_mod.NodeIndex,
        @fromBackingInt(@intCast(@as(u32, @intCast(ast.nodes.items.len - 1)))),
    );
    if (root_idx.isNone() or @backingInt(root_idx) >= ast.nodes.items.len or
        ast.getNode(root_idx).tag != .program) return false;
    const reachable_nodes = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, root_idx) catch return false;
    defer ast.allocator.free(reachable_nodes);
    for (reachable_nodes) |raw| {
        if (raw >= ast.nodes.items.len) return false;
        const node = ast.nodes.items[raw];
        if (node.tag != .class_declaration and node.tag != .class_expression) continue;
        const extra = node.data.extra;
        if (extra > ast.extra_data.items.len or
            ast.extra_data.items.len - extra <= ast_mod.ClassExtra.super) return false;
        const super_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra + ast_mod.ClassExtra.super]));
        if (!super_idx.isNone()) return true;
    }
    return false;
}

fn runtimeHelpersSafeForRetainedGraph(
    helpers: @import("../../transformer/runtime_helper_bits.zig").RuntimeHelpers,
    allow_derived_class_helpers: bool,
    allow_stage3_decorator_helpers: bool,
    allow_legacy_decorator_helpers: bool,
    allow_async_helper: bool,
    allow_es5_async_method_super_get: bool,
    allow_es5_async_method_super_set: bool,
) bool {
    var other_helpers = helpers;
    if (allow_async_helper) other_helpers.async_helper = false;
    if (allow_derived_class_helpers) {
        other_helpers.extends = false;
        other_helpers.call_super = false;
        other_helpers.derived_constructor = false;
    }
    other_helpers.generator = false;
    other_helpers.values = false;
    other_helpers.async_values = false;
    other_helpers.read = false;
    other_helpers.rest = false;
    other_helpers.class_call_check = false;
    other_helpers.spread_array = false;
    other_helpers.tagged_template_literal = false;
    other_helpers.keep_names = false;
    // `__toPropertyKey(key)` wraps a hoisted computed field key (#5553); like
    // the class-call check it is a plain helper call with a tracked reference.
    other_helpers.to_property_key = false;
    // `__superGet` and `__superSet` are safe when every reachable super use
    // belongs to an ES5 async class/object method with an admitted home graph.
    if (allow_es5_async_method_super_get) other_helpers.super_get = false;
    if (allow_es5_async_method_super_set) other_helpers.super_set = false;
    if (allow_stage3_decorator_helpers) other_helpers.es_decorator = false;
    if (allow_legacy_decorator_helpers) {
        other_helpers.legacy_decorator = false;
        if (helpers.legacy_decorator) other_helpers.metadata = false;
    }
    return !other_helpers.hasAny();
}

test "retained legacy decorators admit their tracked metadata helper" {
    const RuntimeHelpers = @import("../../transformer/runtime_helper_bits.zig").RuntimeHelpers;
    const helpers: RuntimeHelpers = .{ .legacy_decorator = true, .metadata = true };
    try std.testing.expect(runtimeHelpersSafeForRetainedGraph(helpers, false, false, true, false, false, false));
    try std.testing.expect(!runtimeHelpersSafeForRetainedGraph(helpers, false, false, false, false, false, false));
    const metadata_only: RuntimeHelpers = .{ .metadata = true };
    try std.testing.expect(!runtimeHelpersSafeForRetainedGraph(metadata_only, false, false, true, false, false, false));
}

/// Stage 3 decorators are always lowered by the transformer, even when the
/// selected JavaScript target leaves class syntax native. Keep that narrow
/// path on the edited semantic graph only when no other syntax lowering or
/// plugin can change the same scopes. Legacy metadata is admitted separately
/// below because its helper references are recorded in the edited graph.
fn canRetainStage3DecoratorGraph(
    ast: *const ast_mod.Ast,
    options: TransformOptions,
) bool {
    return ast.has_decorator and
        !options.unsupportedGraphPrePassFeatureUsed(ast) and
        !options.experimental_decorators and
        !options.emit_decorator_metadata and
        !options.minify_syntax and
        !options.react_refresh and
        !options.styled_components and
        !options.emotion and
        !ast.has_jsx and
        !ast.has_ts_namespace_or_enum and
        !ast.has_ts_import_equals and
        !ast.has_ts_export_equals;
}

/// Legacy decorators are lowered by the transformer even when class syntax
/// remains native. Their helper imports and generated references are recorded
/// in the edited semantic graph. Flow input is supported when it is a runtime
/// module; `.js.flow` and `.jsx.flow` declaration files, syntax minification,
/// downlevel syntax, and plugins with undeclared graph effects stay on the
/// conservative analyzer path. Metadata can use this path when its generated
/// helper references are also admitted by the retained-graph gate.
fn canRetainLegacyDecoratorGraph(
    module: *const Module,
    ast: *const ast_mod.Ast,
    options: TransformOptions,
) bool {
    return ast.has_decorator and
        options.experimental_decorators and
        !isFlowPath(module.path) and
        !options.unsupportedGraphPrePassFeatureUsed(ast) and
        !options.minify_syntax and
        !options.react_refresh and
        !options.styled_components and
        !options.emotion and
        !ast.has_jsx and
        !ast.has_ts_namespace_or_enum and
        !ast.has_ts_import_equals and
        !ast.has_ts_export_equals;
}

test "legacy decorator graph retention gate includes Flow and excludes graph-changing modes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "function mark(value: any): any { return value; } @mark class Example { @mark method() {} }";
    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    defer parser.deinit();
    _ = try parser.parse();

    var module = Module.init(@fromBackingInt(@as(u32, 0)), "input.ts");
    const options: TransformOptions = .{ .experimental_decorators = true };
    try std.testing.expect(canRetainLegacyDecoratorGraph(&module, &parser.ast, options));

    var flow_scanner = try Scanner.init(
        allocator,
        "// @flow\nfunction mark(value) { return value; } @mark class Example { @mark method() {} }",
    );
    defer flow_scanner.deinit();
    var flow_parser = @import("../../parser/parser.zig").Parser.init(allocator, &flow_scanner);
    flow_parser.configureFromExtension(".js");
    defer flow_parser.deinit();
    _ = try flow_parser.parse();
    try std.testing.expect(flow_parser.is_flow);
    try std.testing.expectEqual(@as(usize, 0), flow_parser.errors.items.len);
    try std.testing.expect(flow_parser.ast.has_decorator);

    const flow_module = Module.init(@fromBackingInt(@as(u32, 1)), "input.js");
    try std.testing.expect(canRetainLegacyDecoratorGraph(&flow_module, &flow_parser.ast, options));
    const flow_declaration_module = Module.init(@fromBackingInt(@as(u32, 2)), "input.js.flow");
    try std.testing.expect(!canRetainLegacyDecoratorGraph(&flow_declaration_module, &flow_parser.ast, options));
    try std.testing.expect(canRetainLegacyDecoratorGraph(
        &module,
        &parser.ast,
        .{ .experimental_decorators = true, .emit_decorator_metadata = true },
    ));
    try std.testing.expect(!canRetainLegacyDecoratorGraph(
        &module,
        &parser.ast,
        .{ .experimental_decorators = true, .minify_syntax = true },
    ));
    try std.testing.expect(!canRetainLegacyDecoratorGraph(
        &module,
        &parser.ast,
        .{ .experimental_decorators = true, .unsupported = .{ .class = true } },
    ));
    try std.testing.expect(!canRetainLegacyDecoratorGraph(
        &module,
        &parser.ast,
        .{ .experimental_decorators = true, .react_refresh = true },
    ));
    try std.testing.expect(!canRetainLegacyDecoratorGraph(
        &module,
        &parser.ast,
        .{ .experimental_decorators = true, .styled_components = true },
    ));
    try std.testing.expect(!canRetainLegacyDecoratorGraph(
        &module,
        &parser.ast,
        .{ .experimental_decorators = true, .emotion = true },
    ));
    var jsx_ast = parser.ast;
    jsx_ast.has_jsx = true;
    try std.testing.expect(!canRetainLegacyDecoratorGraph(&module, &jsx_ast, options));
    var ts_namespace_ast = parser.ast;
    ts_namespace_ast.has_ts_namespace_or_enum = true;
    try std.testing.expect(!canRetainLegacyDecoratorGraph(&module, &ts_namespace_ast, options));
    var ts_import_equals_ast = parser.ast;
    ts_import_equals_ast.has_ts_import_equals = true;
    try std.testing.expect(!canRetainLegacyDecoratorGraph(&module, &ts_import_equals_ast, options));
    var ts_export_equals_ast = parser.ast;
    ts_export_equals_ast.has_ts_export_equals = true;
    try std.testing.expect(!canRetainLegacyDecoratorGraph(&module, &ts_export_equals_ast, options));
    try std.testing.expect(!canRetainLegacyDecoratorGraph(&module, &parser.ast, .{}));
    try std.testing.expect(!canRetainLegacyDecoratorGraph(
        &module,
        &parser.ast,
        .{ .emit_decorator_metadata = true },
    ));
}

test "bundler retains graph for decorator options without decorator syntax" {
    const cases = [_]struct {
        source: []const u8,
        experimental_decorators: bool,
        emit_decorator_metadata: bool,
    }{
        .{ .source = "const value: number = 1;", .experimental_decorators = true, .emit_decorator_metadata = true },
        .{ .source = "function read(value: number): number { return value; }", .experimental_decorators = false, .emit_decorator_metadata = true },
        .{ .source = "type Value = string; const value: Value = 'x';", .experimental_decorators = true, .emit_decorator_metadata = false },
        .{ .source = "interface Shape { name: string } const value: Shape = { name: 'x' };", .experimental_decorators = true, .emit_decorator_metadata = true },
        .{ .source = "const value = 1 as number;", .experimental_decorators = false, .emit_decorator_metadata = true },
        .{ .source = "const value = 1 satisfies number;", .experimental_decorators = true, .emit_decorator_metadata = false },
        .{ .source = "function read<T extends object>(value: T): T { return value; }", .experimental_decorators = true, .emit_decorator_metadata = true },
        .{ .source = "class Box { value: number = 1; read(): number { return this.value; } }", .experimental_decorators = false, .emit_decorator_metadata = true },
        .{ .source = "const values: Array<number> = [1, 2];", .experimental_decorators = true, .emit_decorator_metadata = false },
        .{ .source = "import type { Shape } from './shape'; const shape: Shape = { name: 'x' };", .experimental_decorators = false, .emit_decorator_metadata = false },
    };
    const Plugin = @import("../plugin.zig").Plugin;
    const no_plugins: []const Plugin = &.{};

    for (cases, 0..) |case, case_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try Scanner.init(allocator, case.source);
        var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
        parser.configureFromExtension(".ts");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        try std.testing.expect(!parser.ast.has_decorator);

        var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
        analyzer.is_strict_mode = parser.is_strict_mode;
        analyzer.is_module = parser.is_module;
        analyzer.is_ts = true;
        try analyzer.analyze();

        var module = Module.init(@fromBackingInt(@intCast(case_index)), "input.ts");
        module.source = case.source;
        module.module_type = .ts;
        module.ast = parser.ast;
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

        const context = .{
            .allocator = allocator,
            .flow = false,
            .worklet_transform = false,
            .plugins = no_plugins,
            .styled_components = false,
            .emotion = false,
        };
        var allow_super_get = false;
        var allow_super_set = false;
        const options: TransformOptions = .{
            .strip_types = true,
            .experimental_decorators = case.experimental_decorators,
            .emit_decorator_metadata = case.emit_decorator_metadata,
        };
        try std.testing.expect(canKeepPrepassSemanticGraph(
            &context,
            &module,
            options,
            no_plugins,
            &allow_super_get,
            &allow_super_set,
            null,
        ));
    }

    var decorated_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer decorated_arena.deinit();
    const allocator = decorated_arena.allocator();
    const decorated_source = "function mark(value: Function) {} @mark class Example {}";
    var scanner = try Scanner.init(allocator, decorated_source);
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    try std.testing.expect(parser.ast.has_decorator);
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_ts = true;
    try analyzer.analyze();
    var decorated_module = Module.init(@fromBackingInt(@as(u32, 0)), "decorated.ts");
    decorated_module.source = decorated_source;
    decorated_module.module_type = .ts;
    decorated_module.ast = parser.ast;
    decorated_module.semantic = .{
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
    const decorated_context = .{
        .allocator = allocator,
        .flow = false,
        .worklet_transform = false,
        .plugins = no_plugins,
        .styled_components = false,
        .emotion = false,
    };
    var allow_super_get = false;
    var allow_super_set = false;
    try std.testing.expect(canKeepPrepassSemanticGraph(
        &decorated_context,
        &decorated_module,
        .{ .strip_types = true, .experimental_decorators = true, .emit_decorator_metadata = true },
        no_plugins,
        &allow_super_get,
        &allow_super_set,
        null,
    ));
    try std.testing.expect(!canKeepPrepassSemanticGraph(
        &decorated_context,
        &decorated_module,
        .{
            .strip_types = true,
            .experimental_decorators = true,
            .emit_decorator_metadata = true,
            .minify_syntax = true,
        },
        no_plugins,
        &allow_super_get,
        &allow_super_set,
        null,
    ));
}

fn hasClassFieldSyntax(ast: *const ast_mod.Ast) bool {
    for (ast.nodes.items) |node| {
        if (node.tag == .property_definition) return true;
    }
    return false;
}

fn hasWorkletTransformSignal(ast: *const ast_mod.Ast, substitute_web_platform_checks: bool) bool {
    if (hasFileWorkletDirective(ast)) return true;

    const worklet = worklet_plugin.plugin();
    for (ast.nodes.items) |node| {
        switch (node.tag) {
            .function_declaration,
            .function_expression,
            .function,
            .arrow_function_expression,
            .method_definition,
            => if (functionHasWorkletDirective(ast, node)) return true,
            .identifier_reference => {
                const name = ast.getText(node.span);
                if (std.mem.eql(u8, name, "__workletContextObject") or
                    std.mem.eql(u8, name, "__workletClass")) return true;
            },
            .call_expression => {
                const name = workletCallCalleeName(ast, node) orelse continue;
                for (worklet.autoWorkletCallees) |callee| {
                    if (std.mem.eql(u8, callee.name, name)) return true;
                }
                if (substitute_web_platform_checks) {
                    for (worklet_plugin.WEB_PLATFORM_CHECK_NAMES) |web_name| {
                        if (std.mem.eql(u8, web_name, name)) return true;
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

fn hasFileWorkletDirective(ast: *const ast_mod.Ast) bool {
    if (ast.nodes.items.len == 0) return false;
    const root_idx = ast.transformed_root orelse @as(
        ast_mod.NodeIndex,
        @fromBackingInt(@intCast(@as(u32, @intCast(ast.nodes.items.len - 1)))),
    );
    if (root_idx.isNone() or @backingInt(root_idx) >= ast.nodes.items.len) return true;
    const root = ast.getNode(root_idx);
    if (root.tag != .program) return true;

    const list = root.data.list;
    if (list.start > ast.extra_data.items.len or list.len > ast.extra_data.items.len - list.start) return true;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const raw_stmt = ast.extra_data.items[list.start + i];
        if (raw_stmt >= ast.nodes.items.len) return true;
        const text = worklet_mod.directiveText(ast, @fromBackingInt(@intCast(raw_stmt))) orelse return false;
        if (std.mem.eql(u8, text, "worklet")) return true;
    }
    return false;
}

fn workletCallCalleeName(ast: *const ast_mod.Ast, node: ast_mod.Node) ?[]const u8 {
    const extras = ast.extra_data.items;
    const call_extra = node.data.extra;
    if (call_extra >= extras.len) return null;
    const callee_raw = extras[call_extra];
    if (callee_raw >= ast.nodes.items.len) return null;
    const callee = ast.nodes.items[callee_raw];
    return switch (callee.tag) {
        .identifier_reference => ast.getText(callee.span),
        .static_member_expression => blk: {
            const member_extra = callee.data.extra;
            if (member_extra >= extras.len or extras.len - member_extra <= 1) break :blk null;
            const property_raw = extras[member_extra + 1];
            if (property_raw >= ast.nodes.items.len) break :blk null;
            break :blk ast.getText(ast.nodes.items[property_raw].span);
        },
        else => null,
    };
}

fn functionHasWorkletDirective(ast: *const ast_mod.Ast, node: ast_mod.Node) bool {
    const body_idx = ast.functionBodyBlock(node) orelse return false;
    const body_raw = @backingInt(body_idx);
    if (body_raw >= ast.nodes.items.len) return true;
    const body = ast.nodes.items[body_raw];
    if (body.tag != .block_statement and body.tag != .function_body) return true;
    const list = body.data.list;
    if (list.start > ast.extra_data.items.len or list.len > ast.extra_data.items.len - list.start) return true;
    const scan_len = @min(list.len, 5);
    var i: u32 = 0;
    while (i < scan_len) : (i += 1) {
        const raw_stmt = ast.extra_data.items[list.start + i];
        if (raw_stmt >= ast.nodes.items.len) return true;
        const text = worklet_mod.directiveText(ast, @fromBackingInt(@intCast(raw_stmt))) orelse continue;
        if (std.mem.eql(u8, text, "worklet")) return true;
    }
    return false;
}

/// A nested function with its own Worklet directive is rewritten independently
/// of its enclosing function. Keep that case on semantic reanalysis until the
/// generated wrapper's output scope is tracked across that nested boundary.
/// Nested helper functions in explicit and file-level Worklets keep their
/// source scopes and share the edited graph; unsupported syntax remains gated
/// by the other prepass checks.
fn hasNestedWorkletFunctionScope(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
) bool {
    for (ast.nodes.items, 0..) |node, raw| {
        switch (node.tag) {
            .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition => {},
            else => continue,
        }
        if (!functionHasWorkletDirective(ast, node)) continue;
        const raw_scope = semantic.scope_owner_map.get(@intCast(raw)) orelse return true;
        if (raw_scope >= semantic.scopes.len) return true;
        const scope = semantic.scopes[raw_scope];
        if (scope.kind != .function) return true;
        var parent = scope.parent;
        var hops: usize = 0;
        while (!parent.isNone() and hops < semantic.scopes.len) : (hops += 1) {
            const parent_index = parent.toIndex();
            if (parent_index >= semantic.scopes.len) return true;
            if (semantic.scopes[parent_index].kind == .function) return true;
            parent = semantic.scopes[parent_index].parent;
        }
        if (!parent.isNone()) return true;
    }
    return false;
}

/// Retain the graph for string and primitive define replacements only
/// when every matching AST candidate is one exact, bound local identifier
/// read. Composite expressions and dynamic scopes retain the full semantic
/// reanalysis path.
fn canRetainGraphForSimpleDefineReferences(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    defines: []const define_mod.DefineEntry,
) bool {
    if (semantic.scopes.len == 0) return false;

    const ReferenceIdentity = struct {
        symbol_id: u32,
        scope_id: u32,
        ambiguous: bool = false,
    };
    var references_by_node: std.AutoHashMapUnmanaged(u32, ReferenceIdentity) = .empty;
    defer references_by_node.deinit(allocator);
    for (semantic.references) |reference| {
        if (reference.node_index.isNone()) continue;
        const raw = @backingInt(reference.node_index);
        if (references_by_node.getPtr(raw)) |existing| {
            existing.ambiguous = true;
            continue;
        }
        references_by_node.put(allocator, raw, .{
            .symbol_id = @backingInt(reference.symbol_id),
            .scope_id = @backingInt(reference.scope_id),
        }) catch return false;
    }

    var found_define = false;
    for (ast.nodes.items, 0..) |node, raw| {
        const value = define_mod.matchedDefineValue(ast, node, defines) orelse continue;
        found_define = true;
        if (node.tag != .identifier_reference or
            (!define_mod.isStringLiteralDefineValue(value) and
                !define_mod.isGraphSafePrimitiveDefineValue(value))) return false;
        if (raw >= semantic.symbol_ids.len) return false;
        const symbol_id = semantic.symbol_ids[raw] orelse return false;
        if (symbol_id >= semantic.symbols.items.len) return false;
        const reference = references_by_node.get(@intCast(raw)) orelse return false;
        if (reference.ambiguous or reference.symbol_id != symbol_id or
            reference.scope_id >= semantic.scopes.len) return false;
        const symbol = semantic.symbols.items[symbol_id];
        if (symbol.kind == .import_binding or symbol.synthetic_kind != null or
            symbol.scope_id.isNone() or @backingInt(symbol.scope_id) >= semantic.scopes.len)
        {
            return false;
        }
    }
    return found_define;
}

const SimpleConsoleDrop = struct {
    object_reference: u32,
};

/// A direct `console.member(...)` statement is a retained-graph candidate when
/// its callee is a statically named console reference. Arguments are removed
/// with the call; after the semantic edit, the exact graph gate checks every
/// surviving binding/reference/scope and falls back to analysis if that edit
/// left any inconsistent edge.
fn simpleConsoleDropShape(ast: *const ast_mod.Ast, statement: ast_mod.Node) ?SimpleConsoleDrop {
    if (statement.tag != .expression_statement) return null;
    const call_index = statement.data.unary.operand;
    if (call_index.isNone() or @backingInt(call_index) >= ast.nodes.items.len) return null;
    const call = ast.getNode(call_index);
    if (call.tag != .call_expression) return null;
    const extra = call.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 4) return null;
    const extras = ast.extra_data.items;
    if ((extras[extra + 3] & ast_mod.CallFlags.optional_chain) != 0) return null;
    const callee_raw = extras[extra];
    if (callee_raw >= ast.nodes.items.len) return null;
    const callee = ast.nodes.items[callee_raw];
    if (callee.tag != .static_member_expression and callee.tag != .computed_member_expression) return null;
    const member_extra = callee.data.extra;
    if (member_extra > extras.len or extras.len - member_extra < 2) return null;
    const object_raw = extras[member_extra];
    if (object_raw >= ast.nodes.items.len) return null;
    const object = ast.nodes.items[object_raw];
    if (object.tag != .identifier_reference or
        !std.mem.eql(u8, ast.getText(object.data.string_ref), "console")) return null;
    if (callee.tag == .computed_member_expression) {
        if (extras.len - member_extra < 3 or
            (extras[member_extra + 2] & ast_mod.MemberFlags.optional_chain) != 0) return null;
        const property_raw = extras[member_extra + 1];
        if (property_raw >= ast.nodes.items.len) return null;
        const property_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(property_raw));
        if (ast.nodes.items[property_raw].tag != .string_literal and
            !drop_mod.isNoSubstitutionTemplateLiteral(ast, property_idx)) return null;
    }

    const args_start: usize = extras[extra + 1];
    const args_len: usize = extras[extra + 2];
    if (args_start > extras.len or args_len > extras.len - args_start) return null;
    for (extras[args_start .. args_start + args_len]) |raw_arg| {
        if (raw_arg >= ast.nodes.items.len) return null;
    }
    return .{
        .object_reference = object_raw,
    };
}

/// Collect exact `console` read nodes for the graph-retained drop path. The
/// transformer uses these to instantiate semantic editing before finishing;
/// finishSemanticEdit then removes every reference in the now-unreachable
/// dropped call, including references nested inside its arguments.
fn collectRetainedConsoleObjectReferences(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
) ?[]ast_mod.NodeIndex {
    if (ast.nodes.items.len == 0) return null;
    const root = ast.transformed_root orelse @as(
        ast_mod.NodeIndex,
        @fromBackingInt(@intCast(@as(u32, @intCast(ast.nodes.items.len - 1)))),
    );
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len or
        ast.getNode(root).tag != .program) return null;
    const reachable_nodes = ast_walk.collectReachableNodeIndicesFrom(allocator, ast, root) catch return null;
    defer allocator.free(reachable_nodes);

    var references: std.ArrayListUnmanaged(ast_mod.NodeIndex) = .empty;
    for (reachable_nodes) |raw_node| {
        const statement = ast.nodes.items[raw_node];
        if (!drop_mod.isConsoleCallInAst(ast, statement)) continue;
        const shape = simpleConsoleDropShape(ast, statement) orelse return null;
        references.append(allocator, @fromBackingInt(shape.object_reference)) catch return null;
    }
    return references.toOwnedSlice(allocator) catch null;
}

fn hasExactLocalReference(
    semantic: *const ModuleSemanticData,
    raw_node: u32,
    expected_scope: u32,
) bool {
    if (raw_node >= semantic.symbol_ids.len) return false;
    const symbol_id = semantic.symbol_ids[raw_node] orelse return false;
    if (symbol_id >= semantic.symbols.items.len) return false;
    var found = false;
    for (semantic.references) |reference| {
        if (reference.node_index.isNone() or @backingInt(reference.node_index) != raw_node) continue;
        if (found or @backingInt(reference.symbol_id) != symbol_id or
            reference.scope_id.isNone() or @backingInt(reference.scope_id) >= semantic.scopes.len or
            @backingInt(reference.scope_id) != expected_scope) return false;
        found = true;
    }
    const symbol = semantic.symbols.items[symbol_id];
    return found and symbol.kind != .import_binding and symbol.synthetic_kind == null and
        !symbol.scope_id.isNone() and @backingInt(symbol.scope_id) < semantic.scopes.len;
}

fn sourceReferenceScope(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    parents: *const std.AutoHashMapUnmanaged(u32, u32),
    raw_node: u32,
) ?u32 {
    var current = raw_node;
    var hops: usize = 0;
    while (hops <= ast.nodes.items.len) : (hops += 1) {
        if (semantic.scope_owner_map.get(current)) |scope| {
            if (scope >= semantic.scopes.len) return null;
            return scope;
        }
        current = parents.get(current) orelse return null;
    }
    return null;
}

/// Read native top-level await from the current AST and retained scope graph.
/// A function boundary makes an await local to that function; block and catch
/// scopes continue toward the module/global root. Missing owner evidence fails
/// closed so callers can use full semantic analysis.
fn hasTopLevelAwaitInRetainedGraph(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    scopes: []const SemanticScope,
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
) ?bool {
    if (scopes.len == 0 or ast.nodes.items.len == 0) return null;
    const root = ast.transformed_root orelse @as(
        ast_mod.NodeIndex,
        @fromBackingInt(@intCast(@as(u32, @intCast(ast.nodes.items.len - 1)))),
    );
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len or
        ast.getNode(root).tag != .program) return null;
    var parents: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer parents.deinit(allocator);
    if (!collectRetainedPreflightParents(allocator, ast, root, &parents)) return null;
    const reachable = ast_walk.collectReachableNodeIndicesFrom(allocator, ast, root) catch return null;
    defer allocator.free(reachable);

    for (reachable) |raw| {
        if (raw >= ast.nodes.items.len) continue;
        const tag = ast.nodes.items[raw].tag;
        // The semantic analyzer records both native `await` and top-level
        // `for await` in its module-local bit. Keep the scan in sync with that
        // contract; a for-await loop does not need an await_expression node.
        if (tag != .await_expression and tag != .for_await_of_statement) continue;
        var current_node: u32 = @intCast(raw);
        var scope_id: ?u32 = null;
        var parent_hops: usize = 0;
        while (parent_hops <= ast.nodes.items.len) : (parent_hops += 1) {
            if (scope_owner_map.get(current_node)) |owner| {
                scope_id = owner;
                break;
            }
            current_node = parents.get(current_node) orelse return null;
        }
        var current_scope = scope_id orelse return null;
        var hops: usize = 0;
        while (hops < scopes.len) : (hops += 1) {
            if (current_scope >= scopes.len) return null;
            const scope = scopes[current_scope];
            switch (scope.kind) {
                .function => break,
                .global, .module => return true,
                .block, .switch_block, .catch_clause, .class_body => {
                    if (scope.parent.isNone()) return null;
                    current_scope = @backingInt(scope.parent);
                },
            }
        }
    }
    return false;
}

fn refreshRetainedModuleTopLevelAwait(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    module: *Module,
) bool {
    const semantic = module.semantic orelse return false;
    const has_tla = hasTopLevelAwaitInRetainedGraph(
        allocator,
        ast,
        semantic.scopes,
        &semantic.scope_owner_map,
    ) orelse return false;
    module.self_uses_top_level_await = has_tla;
    return true;
}

fn shouldRefreshRetainedModuleTopLevelAwait(
    can_keep_semantic_graph: bool,
    retained_simple_console_drops: bool,
    has_dropped_labeled_statement: bool,
    module_self_uses_top_level_await: bool,
) bool {
    return can_keep_semantic_graph and
        (retained_simple_console_drops or has_dropped_labeled_statement) and
        module_self_uses_top_level_await;
}

fn canRetainGraphForSimpleConsoleDrops(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
) bool {
    if (semantic.scopes.len == 0 or ast.nodes.items.len == 0) return false;
    const root = ast.transformed_root orelse @as(
        ast_mod.NodeIndex,
        @fromBackingInt(@intCast(@as(u32, @intCast(ast.nodes.items.len - 1)))),
    );
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len or
        ast.getNode(root).tag != .program) return false;
    var parents: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer parents.deinit(allocator);
    if (!collectRetainedPreflightParents(allocator, ast, root, &parents)) return false;
    const reachable_nodes = ast_walk.collectReachableNodeIndices(allocator, ast) catch return false;
    defer allocator.free(reachable_nodes);
    var found_drop = false;
    for (reachable_nodes) |raw_node| {
        const statement = ast.nodes.items[raw_node];
        if (!drop_mod.isConsoleCallInAst(ast, statement)) continue;
        found_drop = true;
        const shape = simpleConsoleDropShape(ast, statement) orelse return false;
        const expected_scope = sourceReferenceScope(ast, semantic, &parents, shape.object_reference) orelse return false;
        if (!hasExactLocalReference(semantic, shape.object_reference, expected_scope) and
            !isUnresolvedSourceIdentifierReference(
                ast,
                semantic,
                @fromBackingInt(shape.object_reference),
            )) return false;
    }
    return found_drop;
}

fn canKeepPrepassSemanticGraph(
    self: anytype,
    module: *const Module,
    options: TransformOptions,
    plugins: anytype,
    allow_es5_async_method_super_get: *bool,
    allow_es5_async_method_super_set: *bool,
    retained_simple_console_drops_out: ?*bool,
) bool {
    allow_es5_async_method_super_get.* = false;
    allow_es5_async_method_super_set.* = false;
    if (retained_simple_console_drops_out) |out| out.* = false;
    if (module.ast == null or module.semantic == null) return false;
    const ast = &module.ast.?;
    const semantic = &module.semantic.?;
    var top_level_statements: ?std.DynamicBitSet = null;
    defer {
        if (top_level_statements) |*mask| mask.deinit();
    }
    // The Reanimated visitor edits only the module AST. Its generated factory
    // bindings/references and scopes, plus React Refresh registration handles
    // and component references, are attached to the semantic editor. Preserve
    // that graph for their bounded combination. Arbitrary user plugins remain
    // on the full reanalysis path because their graph effects are not declared
    // to the transformer.
    const safe_builtin_worklet = self.worklet_transform and self.plugins.len == 0 and
        !self.styled_components and !self.emotion and
        !options.unsupported.hasAny() and !ast.has_jsx and !ast.has_decorator and
        !hasNestedWorkletFunctionScope(ast, semantic) and
        isBuiltinWorkletPluginSet(plugins) and isBuiltinWorkletPluginSet(options.plugins);
    if ((self.worklet_transform and !safe_builtin_worklet) or self.plugins.len != 0 or
        (plugins.len != 0 and !safe_builtin_worklet) or
        (options.plugins.len != 0 and !safe_builtin_worklet)) return false;
    // The styled-components CSS-prop visitor adds a real AST import and exact
    // helper SymbolId. The retained-graph path rescans import/export metadata
    // from that edited AST without replacing its semantic graph.
    if (!options.strip_types) return false;
    const classic_jsx = ast.has_jsx and options.jsx_transform and options.jsx_runtime == .classic;
    const automatic_jsx = ast.has_jsx and options.jsx_transform and options.jsx_runtime == .automatic;
    const automatic_dev_jsx = ast.has_jsx and options.jsx_transform and options.jsx_runtime == .automatic_dev;
    const graph_editable_jsx = classic_jsx or automatic_jsx or automatic_dev_jsx;
    const retained_stage3_decorators = canRetainStage3DecoratorGraph(ast, options);
    const retained_legacy_decorators = canRetainLegacyDecoratorGraph(
        module,
        ast,
        options,
    );
    var retainable_async_method_super_get = false;
    var retainable_async_method_super_set = false;
    const safe_graph_subset = options.unsupported.hasAny() and
        canRetainGraphForAuditedSyntaxSubset(
            self.allocator,
            ast,
            semantic,
            options,
            &retainable_async_method_super_get,
            &retainable_async_method_super_set,
        );
    const uses_define = define_mod.astUsesDefine(ast, options.define);
    const retained_simple_define = uses_define and canRetainGraphForSimpleDefineReferences(
        self.allocator,
        ast,
        semantic,
        options.define,
    );
    const has_drop_console = options.drop_console and hasDroppedConsoleStatement(ast);
    const retained_simple_console_drops = has_drop_console and canRetainGraphForSimpleConsoleDrops(
        self.allocator,
        ast,
        semantic,
    );
    if (retained_simple_console_drops_out) |out| out.* = retained_simple_console_drops;
    const has_dropped_labeled_statement = hasDroppedLabeledStatement(ast, options.drop_labels);
    if ((ast.has_jsx and !graph_editable_jsx) or
        (ast.has_decorator and !retained_stage3_decorators and !retained_legacy_decorators)) return false;
    // Syntax minification is admitted provisionally. After it runs, the caller
    // retains this graph only if every reachable binding/reference still has
    // its exact identity and the reference counts still match. A minify edit
    // that removes or relocates semantic nodes falls back to the analyzer.
    // Whitespace minification changes emission and helper spellings, but the
    // transformer records those helper identities in the edited graph.
    // Decorator options are a no-op when the AST contains no decorators. Keep
    // their analyzer fallback only for actual decorator lowering/metadata.
    const has_legacy_decorator_options = options.experimental_decorators or options.emit_decorator_metadata;
    if ((options.unsupported.hasAny() and !safe_graph_subset and !retained_stage3_decorators and !retained_legacy_decorators) or
        (has_drop_console and !retained_simple_console_drops) or
        (uses_define and !retained_simple_define) or
        options.hasMappedImportToSplit(ast) or
        (!options.use_define_for_class_fields and hasClassFieldSyntax(ast)) or
        (ast.has_decorator and has_legacy_decorator_options and !retained_legacy_decorators)) return false;
    const has_top_level_await = module.uses_top_level_await or module.self_uses_top_level_await;
    // The parser already records native TLA exactly. Lowered TLA moves await
    // into a generated async IIFE, so keep that case on the full resync path.
    // The TLA wrapper/deferral options only affect this program-level lowering
    // when the module actually contains top-level await.
    if (has_top_level_await and options.unsupported.top_level_await) return false;
    // Label and console deletion update the module-local TLA bit from the
    // retained AST after editing.
    if (!hasSupportedTopLevelExportDeclarations(module)) return false;
    const allow_nonverbatim_javascript_imports = canRetainPlainJavaScriptImportsForConsoleDrop(
        self,
        module,
        ast,
        options,
        retained_simple_console_drops,
    );
    if (!hasStableRuntimeImports(ast, options, allow_nonverbatim_javascript_imports)) return false;

    const safe_styled_components = options.styled_components;
    // `drop_debugger` removes a statement with no binding or reference edges,
    // so it does not make the semantic graph preflight a graph-changing pass.
    var found_transform = graph_editable_jsx or retained_stage3_decorators or retained_legacy_decorators or safe_graph_subset or retained_simple_define or
        retained_simple_console_drops or has_dropped_labeled_statement or safe_styled_components or
        options.react_refresh or options.emotion or safe_builtin_worklet;
    var has_direct_eval = false;
    for (semantic.scopes) |scope| {
        if (scope.subtree_has_direct_eval) {
            has_direct_eval = true;
            break;
        }
    }
    for (ast.nodes.items, 0..) |node, raw_node_idx| {
        const tag_name = @tagName(node.tag);
        const is_flow_match_tag = std.mem.startsWith(u8, tag_name, "flow_match_");
        const is_flow_enum_tag = node.tag == .flow_enum_declaration or node.tag == .flow_enum_member;
        const is_flow_component_wrapper = node.tag == .flow_component_wrapper;
        if (std.mem.startsWith(u8, tag_name, "flow_") and !is_flow_match_tag and
            !is_flow_enum_tag and !is_flow_component_wrapper and
            !isTypeErasureTag(node.tag)) return false;
        if (isTypeErasureTag(node.tag)) found_transform = true;
        switch (node.tag) {
            .flow_match_expression => found_transform = true,
            // Flow enum bindings and member initializer references already
            // have exact parser identities; lowering preserves those edges.
            .flow_enum_declaration => found_transform = true,
            .flow_enum_member => {},
            // The forwardRef helper binding and its call reference are added
            // to the edited graph by the Flow component visitor.
            .flow_component_wrapper => found_transform = true,
            // `export =` lowers to `module.exports = ...`; parser and AST scans
            // both preserve that CommonJS graph signal before and after lowering.
            .ts_export_assignment => found_transform = true,
            .ts_import_equals_declaration => {
                const local_supported = isSupportedLocalImportEquals(ast, node);
                const external_supported = isSupportedExternalRequireImportEquals(ast, node);
                if (!local_supported and !external_supported) return false;
                found_transform = true;
            },
            .export_all_declaration => {
                const node_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(@as(u32, @intCast(raw_node_idx))));
                if (top_level_statements == null) {
                    top_level_statements = ast_walk.topLevelStatementMask(ast) catch return false;
                }
                const top_level_mask = if (top_level_statements) |*mask| mask else return false;
                if (!isSupportedPlainExportAll(ast, node_idx, top_level_mask)) return false;
                found_transform = true;
            },
            // These constructs can alter the import/export graph or create
            // dynamic-name environments independently of Flow match lowering.
            .ts_namespace_export_declaration,
            .with_statement,
            => return false,
            .yield_expression => {
                // The reachable-node subset validates the generated state and
                // temp identities for synchronous downlevel generators. Async
                // generators and unsupported method forms are rejected there.
            },
            .await_expression => {
                // Top-level await is vetoed above. Await inside a native async
                // function adds no bindings or scopes; when the target needs
                // async lowering, the reachable-node allowlist keeps the
                // module on semantic reanalysis. This scan also sees
                // parser-arena nodes that are not reachable from the program.
            },
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
            .for_of_statement => {
                if (options.unsupported.for_of and !safe_graph_subset) return false;
                // Native visitation copies the loop; the audited ES5 lowering
                // edits its loop-head SymbolIds and records generated output
                // bindings in their scopes. Preserve that exact graph.
                found_transform = true;
            },
            .class_declaration, .class_expression => {
                // The audited subset validates top-level and direct function-body
                // class declarations, plus class expressions used as direct `var`
                // initializers.
                const is_simple_downlevel_class = safe_graph_subset;
                if (options.unsupported.class and !is_simple_downlevel_class) return false;
                // Native classes add no output scopes. Admitted downlevel
                // forms are empty declarations/expressions, plain methods, an empty
                // explicit constructor with plain methods, or those same safe
                // bounded methods/constructors followed by an accessor group; their
                // helper, class reference, and scopes are tracked.
                found_transform = true;
            },
            .identifier_reference => {
                const raw_name = ast.identifierNameText(node);
                if (std.mem.indexOfScalar(u8, raw_name, '\\') != null) {
                    // The exact source SymbolId proves the binding even when
                    // the AST spelling is escaped. The exact scope audit accepts
                    // the analyzer's decoded scope-map alias, so these references
                    // can stay on the parser graph without reanalysis. Check this
                    // before decoding: bound names have no fixed spelling limit.
                    if (isBoundSourceIdentifierReference(
                        ast,
                        semantic,
                        @fromBackingInt(@intCast(@as(u32, @intCast(raw_node_idx)))),
                    )) continue;
                    // Unbound escaped references can leave source-name keyed
                    // external-name reservations ambiguous. A raw or decoded name
                    // in the analyzer's unresolved set is exact external evidence;
                    // otherwise admit only eval with its dynamic-scope marker.
                    const decoded_name = Scanner.decodeIdentifierEscapesAlloc(self.allocator, raw_name) catch return false;
                    defer if (decoded_name.ptr != raw_name.ptr) self.allocator.free(decoded_name);
                    if (semantic.unresolved_references.contains(raw_name) or
                        semantic.unresolved_references.contains(decoded_name)) continue;
                    if (!std.mem.eql(u8, decoded_name, "eval") or !has_direct_eval) return false;
                } else if (std.mem.eql(u8, raw_name, "eval")) {
                    has_direct_eval = true;
                }
            },
            else => {},
        }
    }
    // If the exhaustive preflight found no lowering or plugin edits, the
    // parser's graph is already the exact graph for this module. Retaining it
    // avoids an otherwise unnecessary semantic rescan for ordinary JavaScript
    // (including identifier-only minification, which happens after this pass).
    const unchanged_graph_is_safe = !options.unsupported.hasAny() and
        !ast.has_jsx and !ast.has_decorator and
        !options.react_refresh and !options.emotion and !options.styled_components and
        !safe_builtin_worklet;
    // Dynamic lookup is safe with the parser graph only when this module has
    // no graph-changing work. If any transform edits bindings or scopes, keep
    // the existing full semantic rescan as the recovery boundary.
    // Removing a debugger statement changes no binding or reference edges, so
    // it does not make an otherwise unchanged graph unsafe for direct eval.
    const safe_graph = if (has_direct_eval)
        !found_transform and unchanged_graph_is_safe
    else
        found_transform or unchanged_graph_is_safe;
    allow_es5_async_method_super_get.* = safe_graph and retainable_async_method_super_get;
    allow_es5_async_method_super_set.* = safe_graph and retainable_async_method_super_set;
    return safe_graph;
}

fn minifiedGraphScopeContains(
    scopes: []const SemanticScope,
    binding_scope: ScopeId,
    reference_scope: ScopeId,
) bool {
    if (binding_scope.isNone() or @backingInt(binding_scope) >= scopes.len or
        reference_scope.isNone() or @backingInt(reference_scope) >= scopes.len) return false;
    var current = reference_scope;
    var hops: usize = 0;
    while (hops < scopes.len) : (hops += 1) {
        if (current == binding_scope) return true;
        current = scopes[@backingInt(current)].parent;
        if (current.isNone() or @backingInt(current) >= scopes.len) return false;
    }
    return false;
}

const MinifiedStatementList = struct {
    owner_node: u32,
    children: []const u32,
};

/// Reference rows carry both top-level and per-scope statement indices. Syntax
/// minification may keep every identifier edge while still compacting or
/// reordering one of those statement lists, which would leave those indices
/// stale. Snapshot every statement list before minification and retain the
/// graph only when the exact list owners and child order are unchanged.
fn snapshotMinifiedStatementLists(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
) ![]MinifiedStatementList {
    var lists: std.ArrayListUnmanaged(MinifiedStatementList) = .empty;
    for (ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .program and node.tag != .block_statement) continue;
        const list = node.data.list;
        const start: usize = list.start;
        const end = start + list.len;
        if (end < start or end > ast.extra_data.items.len) return error.InvalidStatementListLayout;
        const children = try allocator.dupe(u32, ast.extra_data.items[start..end]);
        try lists.append(allocator, .{ .owner_node = @intCast(raw), .children = children });
    }
    return lists.toOwnedSlice(allocator);
}

fn minifiedStatementListsEqual(left: []const MinifiedStatementList, right: []const MinifiedStatementList) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a.owner_node != b.owner_node or !std.mem.eql(u32, a.children, b.children)) return false;
    }
    return true;
}

const MinifiedStatementContext = struct {
    stmt_idx: u32 = SemanticReference.NO_STMT,
    scope_stmt_idx: u32 = SemanticReference.NO_STMT,
};

const MinifiedStatementFrame = struct {
    node: ast_mod.NodeIndex,
    context: MinifiedStatementContext,
};

/// Recompute the statement coordinates consumed by tree shaking and the
/// emitter's dead-store pass, while keeping every existing SymbolId and
/// ScopeId. These coordinates are derived from current AST statement lists;
/// inability to map a graph row exactly makes retention ineligible.
fn collectMinifiedStatementContexts(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    root: ast_mod.NodeIndex,
) ![]?MinifiedStatementContext {
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len) return error.InvalidRoot;
    const contexts = try allocator.alloc(?MinifiedStatementContext, ast.nodes.items.len);
    @memset(contexts, null);
    var stack: std.ArrayListUnmanaged(MinifiedStatementFrame) = .empty;
    try stack.append(allocator, .{ .node = root, .context = .{} });

    while (stack.pop()) |frame| {
        if (frame.node.isNone()) continue;
        const raw: usize = @backingInt(frame.node);
        if (raw >= ast.nodes.items.len) return error.InvalidStatementNode;
        if (contexts[raw]) |existing| {
            if (!std.meta.eql(existing, frame.context)) return error.AmbiguousStatementContext;
            continue;
        }
        contexts[raw] = frame.context;
        const node = ast.nodes.items[raw];
        if (node.tag == .program or node.tag == .block_statement) {
            const list = node.data.list;
            const start: usize = list.start;
            const len: usize = list.len;
            if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start)
                return error.InvalidStatementList;
            for (ast.extra_data.items[start .. start + len], 0..) |child_raw, index| {
                const child: ast_mod.NodeIndex = @fromBackingInt(child_raw);
                var context = frame.context;
                if (node.tag == .program) context.stmt_idx = @intCast(index);
                context.scope_stmt_idx = @intCast(index);
                try stack.append(allocator, .{ .node = child, .context = context });
            }
            continue;
        }

        var children = ast_walk.children(ast, node);
        while (children.next()) |child| {
            try stack.append(allocator, .{ .node = child, .context = frame.context });
        }
    }
    return contexts;
}

fn reindexMinifiedSemanticReferences(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    root: ast_mod.NodeIndex,
    references: []const SemanticReference,
) !?[]SemanticReference {
    const contexts = collectMinifiedStatementContexts(allocator, ast, root) catch return null;
    const updated = try allocator.dupe(SemanticReference, references);
    for (updated) |*reference| {
        const node_index = if (reference.flags.declare)
            reference.declaration_node_index
        else
            reference.node_index;
        if (node_index.isNone() or @backingInt(node_index) >= contexts.len) {
            if (reference.stmt_idx == SemanticReference.NO_STMT or
                reference.scope_stmt_idx == SemanticReference.NO_STMT) return null;
            continue;
        }
        const context = contexts[@backingInt(node_index)] orelse return null;
        if (context.stmt_idx == SemanticReference.NO_STMT or
            context.scope_stmt_idx == SemanticReference.NO_STMT) return null;
        reference.stmt_idx = context.stmt_idx;
        reference.scope_stmt_idx = context.scope_stmt_idx;
    }
    return updated;
}

/// Syntax minification runs after Transformer.finishSemanticEdit. It can fold
/// expressions and discard declarations, so the pre-minify graph is retained
/// only when the final AST still presents the same exact semantic edges.
/// Returning false is a normal conservative fallback, not a compilation error.
const MinifiedGraphGateFailure = enum {
    allocation,
    invalid_reference_or_scope,
    invalid_declaration,
    detached_declaration,
    duplicate_declaration,
    missing_reference,
    invalid_reference_node,
    duplicate_reference,
    reference_counts,
    scope_owners,
    invalid_statement_context,
    missing_binding_identity,
    missing_reference_identity,
    unresolved_reference,
};

fn rejectMinifiedGraphGate(
    failure: ?*MinifiedGraphGateFailure,
    reason: MinifiedGraphGateFailure,
) bool {
    if (failure) |out| out.* = reason;
    return false;
}

/// Import declarations use their local specifier as the declaration anchor:
/// default/namespace bindings use the specifier node itself, while named
/// imports use the local identifier on the right side of the specifier. These
/// nodes do not have the same AST tags as ordinary binding declarations, so
/// collect their exact owners once before the retained-graph gate admits them.
fn collectImportBindingDeclarationNodes(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    declaration_nodes: *std.AutoHashMapUnmanaged(u32, void),
) !bool {
    const statements = ast_walk.topLevelStatementIndices(ast) orelse return false;
    for (statements) |statement_raw| {
        if (statement_raw >= ast.nodes.items.len) return false;
        const statement = ast.nodes.items[statement_raw];
        if (statement.tag != .import_declaration) continue;
        const extra = statement.data.extra;
        if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 6) return false;
        const import = module_parser.readImportDeclExtras(ast, extra);
        if (import.is_type_only or import.phase != .none or import.attrs_len != 0) continue;
        if (import.specs_start > ast.extra_data.items.len or
            import.specs_len > ast.extra_data.items.len - import.specs_start) return false;
        for (ast.extra_data.items[import.specs_start .. import.specs_start + import.specs_len]) |spec_raw| {
            if (spec_raw >= ast.nodes.items.len) return false;
            const specifier = ast.nodes.items[spec_raw];
            const local_raw = switch (specifier.tag) {
                .import_default_specifier, .import_namespace_specifier => @as(?u32, spec_raw),
                .import_specifier => blk: {
                    if ((specifier.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) break :blk null;
                    const local = specifier.data.binary.right;
                    if (local.isNone() or @backingInt(local) >= ast.nodes.items.len or
                        ast.getNode(local).tag != .identifier_reference) break :blk null;
                    break :blk @as(u32, @backingInt(local));
                },
                else => null,
            };
            if (local_raw) |raw| {
                const result = try declaration_nodes.getOrPut(allocator, raw);
                if (result.found_existing) return false;
                result.value_ptr.* = {};
            }
        }
    }
    return true;
}

fn canRetainMinifiedSemanticGraph(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    root: ast_mod.NodeIndex,
    symbols: []const SemanticSymbol,
    scopes: []const SemanticScope,
    references: []const SemanticReference,
    symbol_ids: []const ?u32,
    unresolved_references: *const std.StringHashMapUnmanaged(void),
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    failure: ?*MinifiedGraphGateFailure,
) bool {
    const reachable = ast_walk.collectReachableNodeIndicesFrom(allocator, ast, root) catch
        return rejectMinifiedGraphGate(failure, .allocation);
    defer allocator.free(reachable);
    const statement_contexts = collectMinifiedStatementContexts(allocator, ast, root) catch
        return rejectMinifiedGraphGate(failure, .allocation);
    const live_reference_nodes = reference_walk.collectIdentifierReferences(allocator, ast, root) catch
        return rejectMinifiedGraphGate(failure, .allocation);
    defer allocator.free(live_reference_nodes);

    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer live.deinit(allocator);
    for (reachable) |raw| live.put(allocator, raw, {}) catch
        return rejectMinifiedGraphGate(failure, .allocation);
    var live_references: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer live_references.deinit(allocator);
    for (live_reference_nodes) |node| {
        live_references.put(allocator, @backingInt(node), {}) catch
            return rejectMinifiedGraphGate(failure, .allocation);
    }

    const scopes_with_owner = allocator.alloc(bool, scopes.len) catch
        return rejectMinifiedGraphGate(failure, .allocation);
    defer allocator.free(scopes_with_owner);
    @memset(scopes_with_owner, false);
    var owner_it = scope_owner_map.iterator();
    while (owner_it.next()) |entry| {
        const owner_node = entry.key_ptr.*;
        const scope_id = entry.value_ptr.*;
        if (!live.contains(owner_node) or owner_node >= ast.nodes.items.len or scope_id >= scopes.len)
            return rejectMinifiedGraphGate(failure, .scope_owners);
        scopes_with_owner[scope_id] = true;
    }
    for (scopes_with_owner) |has_owner| {
        if (!has_owner) return rejectMinifiedGraphGate(failure, .scope_owners);
    }

    var reference_by_node: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer reference_by_node.deinit(allocator);
    var declaration_by_node: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer declaration_by_node.deinit(allocator);
    const reference_counts = allocator.alloc(u32, symbols.len) catch
        return rejectMinifiedGraphGate(failure, .allocation);
    defer allocator.free(reference_counts);
    const write_counts = allocator.alloc(u32, symbols.len) catch
        return rejectMinifiedGraphGate(failure, .allocation);
    defer allocator.free(write_counts);
    @memset(reference_counts, 0);
    @memset(write_counts, 0);
    var import_declaration_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer import_declaration_nodes.deinit(allocator);
    const import_declarations_valid = collectImportBindingDeclarationNodes(
        allocator,
        ast,
        &import_declaration_nodes,
    ) catch return rejectMinifiedGraphGate(failure, .allocation);
    if (!import_declarations_valid) return rejectMinifiedGraphGate(failure, .invalid_declaration);

    for (references) |reference| {
        const symbol_id = @backingInt(reference.symbol_id);
        if (symbol_id >= symbols.len or reference.scope_id.isNone() or
            @backingInt(reference.scope_id) >= scopes.len)
            return rejectMinifiedGraphGate(failure, .invalid_reference_or_scope);

        if (reference.flags.declare) {
            if (!reference.node_index.isNone()) return rejectMinifiedGraphGate(failure, .invalid_declaration);
            if (reference.declaration_node_index.isNone())
                return rejectMinifiedGraphGate(failure, .invalid_declaration);
            const raw = @backingInt(reference.declaration_node_index);
            if (!live.contains(raw)) return rejectMinifiedGraphGate(failure, .detached_declaration);
            if (raw >= ast.nodes.items.len or raw >= symbol_ids.len or
                symbol_ids[raw] != symbol_id or symbols[symbol_id].scope_id != reference.scope_id)
                return rejectMinifiedGraphGate(failure, .invalid_declaration);
            if (ast.nodes.items[raw].tag != .binding_identifier and
                (symbols[symbol_id].kind != .import_binding or
                    !import_declaration_nodes.contains(raw)))
                return rejectMinifiedGraphGate(failure, .invalid_declaration);
            const context = statement_contexts[raw] orelse
                return rejectMinifiedGraphGate(failure, .invalid_statement_context);
            if (reference.stmt_idx != context.stmt_idx or
                reference.scope_stmt_idx != context.scope_stmt_idx)
                return rejectMinifiedGraphGate(failure, .invalid_statement_context);
            if (declaration_by_node.contains(raw)) return rejectMinifiedGraphGate(failure, .duplicate_declaration);
            declaration_by_node.put(allocator, raw, symbol_id) catch
                return rejectMinifiedGraphGate(failure, .allocation);
            continue;
        }

        if (reference.node_index.isNone()) return rejectMinifiedGraphGate(failure, .missing_reference);
        const raw = @backingInt(reference.node_index);
        if (!live_references.contains(raw) or raw >= ast.nodes.items.len or raw >= symbol_ids.len or
            (ast.nodes.items[raw].tag != .identifier_reference and
                ast.nodes.items[raw].tag != .assignment_target_identifier) or
            symbol_ids[raw] != symbol_id or
            !minifiedGraphScopeContains(scopes, symbols[symbol_id].scope_id, reference.scope_id))
            return rejectMinifiedGraphGate(failure, .invalid_reference_node);
        const context = statement_contexts[raw] orelse
            return rejectMinifiedGraphGate(failure, .invalid_statement_context);
        if (reference.stmt_idx != context.stmt_idx or
            reference.scope_stmt_idx != context.scope_stmt_idx)
            return rejectMinifiedGraphGate(failure, .invalid_statement_context);
        if (reference_by_node.contains(raw)) return rejectMinifiedGraphGate(failure, .duplicate_reference);
        reference_by_node.put(allocator, raw, symbol_id) catch
            return rejectMinifiedGraphGate(failure, .allocation);
        reference_counts[symbol_id] +|= 1;
        if (reference.flags.write) write_counts[symbol_id] +|= 1;
    }

    for (symbols, 0..) |symbol, raw| {
        if (symbol.reference_count != reference_counts[raw] or symbol.write_count != write_counts[raw])
            return rejectMinifiedGraphGate(failure, .reference_counts);
    }

    for (reachable) |raw| {
        if (raw >= ast.nodes.items.len) return rejectMinifiedGraphGate(failure, .invalid_reference_node);
        const node = ast.nodes.items[raw];
        if (node.tag != .binding_identifier) continue;
        if (raw >= symbol_ids.len) return rejectMinifiedGraphGate(failure, .missing_binding_identity);
        const symbol_id = symbol_ids[raw] orelse
            return rejectMinifiedGraphGate(failure, .missing_binding_identity);
        if (symbol_id >= symbols.len or declaration_by_node.get(raw) != symbol_id)
            return rejectMinifiedGraphGate(failure, .missing_binding_identity);
    }
    var import_declaration_it = import_declaration_nodes.iterator();
    while (import_declaration_it.next()) |entry| {
        const raw = entry.key_ptr.*;
        if (raw >= symbol_ids.len) return rejectMinifiedGraphGate(failure, .missing_binding_identity);
        const symbol_id = symbol_ids[raw] orelse
            return rejectMinifiedGraphGate(failure, .missing_binding_identity);
        if (symbol_id >= symbols.len or symbols[symbol_id].kind != .import_binding or
            declaration_by_node.get(raw) != symbol_id)
            return rejectMinifiedGraphGate(failure, .missing_binding_identity);
    }

    for (live_reference_nodes) |reference_node| {
        const raw = @backingInt(reference_node);
        if (raw >= ast.nodes.items.len or raw >= symbol_ids.len)
            return rejectMinifiedGraphGate(failure, .missing_reference_identity);
        const node = ast.nodes.items[raw];
        if (symbol_ids[raw]) |symbol_id| {
            if (symbol_id >= symbols.len or reference_by_node.get(raw) != symbol_id)
                return rejectMinifiedGraphGate(failure, .missing_reference_identity);
        } else {
            const text = ast.getText(node.data.string_ref);
            if (!unresolved_references.contains(text)) {
                const decoded = Scanner.decodeIdentifierEscapesAlloc(allocator, text) catch
                    return rejectMinifiedGraphGate(failure, .unresolved_reference);
                if (!unresolved_references.contains(decoded))
                    return rejectMinifiedGraphGate(failure, .unresolved_reference);
            }
        }
    }
    return true;
}

const ImportDeclarationGraphMutation = enum {
    none,
    missing_declaration_row,
    imported_name_as_local_anchor,
};

fn importDeclarationGraphRetainableForTest(mutation: ImportDeclarationGraphMutation) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "import { original as local } from './values.js'; function read() { return local; }";
    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    defer parser.deinit();
    const root = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    defer analyzer.deinit();
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.enable_stmt_info = true;
    try analyzer.analyze();
    const symbol_ids = try allocator.dupe(?u32, analyzer.symbol_ids.items);
    var references: std.ArrayListUnmanaged(SemanticReference) = .empty;
    defer references.deinit(allocator);
    try references.appendSlice(allocator, analyzer.references.items);

    switch (mutation) {
        .none => {},
        .missing_declaration_row => {
            for (references.items, 0..) |reference, index| {
                if (!reference.flags.declare) continue;
                const symbol_id = @backingInt(reference.symbol_id);
                if (symbol_id >= analyzer.symbols.items.len or
                    analyzer.symbols.items[symbol_id].kind != .import_binding) continue;
                _ = references.orderedRemove(index);
                break;
            }
        },
        .imported_name_as_local_anchor => {
            var imported_name: ?u32 = null;
            var local_name: ?u32 = null;
            for (parser.ast.nodes.items) |node| {
                if (node.tag != .import_specifier) continue;
                if (node.data.binary.left.isNone() or node.data.binary.right.isNone()) continue;
                imported_name = @backingInt(node.data.binary.left);
                local_name = @backingInt(node.data.binary.right);
                break;
            }
            const imported_raw = imported_name orelse return error.MissingImportedName;
            const local_raw = local_name orelse return error.MissingLocalName;
            const symbol_id = symbol_ids[local_raw] orelse return error.MissingImportSymbolId;
            symbol_ids[imported_raw] = symbol_id;
            for (references.items) |*reference| {
                if (reference.flags.declare and @backingInt(reference.declaration_node_index) == local_raw) {
                    reference.declaration_node_index = @fromBackingInt(imported_raw);
                    break;
                }
            }
        },
    }

    return canRetainMinifiedSemanticGraph(
        allocator,
        &parser.ast,
        root,
        analyzer.symbols.items,
        analyzer.scopes.items,
        references.items,
        symbol_ids,
        &analyzer.unresolved_references,
        &analyzer.scope_owner_map,
        null,
    );
}

fn syntaxMinifyGraphRetainableForTest(source: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    defer parser.deinit();
    const root = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    defer analyzer.deinit();
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.enable_stmt_info = true;
    try analyzer.analyze();
    const before_statement_lists = try snapshotMinifiedStatementLists(allocator, &parser.ast);
    if (!canRetainMinifiedSemanticGraph(
        allocator,
        &parser.ast,
        root,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.references.items,
        analyzer.symbol_ids.items,
        &analyzer.unresolved_references,
        &analyzer.scope_owner_map,
        null,
    )) return error.InvalidPreMinifyGraph;

    const minify_mod = @import("../../transformer/minify.zig");
    minify_mod.minify(&parser.ast, .{
        .symbols = analyzer.symbols.items,
        .symbol_ids = analyzer.symbol_ids.items,
        .scopes = analyzer.scopes.items,
        .unresolved_globals = &analyzer.unresolved_references,
        .references = analyzer.references.items,
        .allow_top_level_inline = true,
    }, allocator, root);
    const after_statement_lists = try snapshotMinifiedStatementLists(allocator, &parser.ast);
    if (!minifiedStatementListsEqual(before_statement_lists, after_statement_lists)) return false;
    const updated_references = (try reindexMinifiedSemanticReferences(
        allocator,
        &parser.ast,
        root,
        analyzer.references.items,
    )) orelse return false;
    return canRetainMinifiedSemanticGraph(
        allocator,
        &parser.ast,
        root,
        analyzer.symbols.items,
        analyzer.scopes.items,
        updated_references,
        analyzer.symbol_ids.items,
        &analyzer.unresolved_references,
        &analyzer.scope_owner_map,
        null,
    );
}

const MinifiedGraphMutation = enum {
    missing_binding_id,
    invalid_binding_id,
    missing_reference_id,
    invalid_reference_id,
    missing_reference_row,
    duplicate_reference_row,
    wrong_reference_symbol,
    stale_reference_node,
    missing_declaration,
    wrong_declaration_symbol,
    invalid_reference_scope,
    missing_scope_owner,
    invalid_scope_owner,
    wrong_reference_count,
    wrong_write_count,
    missing_statement_index,
    wrong_statement_index,
    wrong_scope_statement_index,
};

fn minifiedGraphMutationIsRejected(mutation: MinifiedGraphMutation) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "const externalValue = external; function read(input) { const alias = input; let count = 0; count = input; return alias + count + externalValue; }";
    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    defer parser.deinit();
    const root = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    defer analyzer.deinit();
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.enable_stmt_info = true;
    try analyzer.analyze();

    const symbol_ids = try allocator.dupe(?u32, analyzer.symbol_ids.items);
    const symbols = try allocator.dupe(SemanticSymbol, analyzer.symbols.items);
    var scope_owner_map = analyzer.scope_owner_map;
    var references: std.ArrayList(SemanticReference) = .empty;
    try references.appendSlice(allocator, analyzer.references.items);

    var binding_node: ?u32 = null;
    var bound_reference_node: ?u32 = null;
    var literal_node: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .binding_identifier and binding_node == null) binding_node = @intCast(raw);
        if (node.tag == .identifier_reference and raw < symbol_ids.len and symbol_ids[raw] != null and
            bound_reference_node == null) bound_reference_node = @intCast(raw);
        if (node.tag == .numeric_literal and literal_node == null) literal_node = @intCast(raw);
    }
    const binding_raw = binding_node orelse return error.MissingHostileBinding;
    const bound_raw = bound_reference_node orelse return error.MissingHostileReference;
    const literal_raw = literal_node orelse return error.MissingHostileLiteral;
    const bound_symbol = symbol_ids[bound_raw] orelse return error.MissingHostileSymbol;
    const binding_symbol = symbol_ids[binding_raw] orelse return error.MissingHostileSymbol;

    var binding_declaration_row: ?usize = null;
    var bound_reference_row: ?usize = null;
    var write_symbol: ?u32 = null;
    for (references.items, 0..) |reference, index| {
        if (reference.flags.declare and @backingInt(reference.declaration_node_index) == binding_raw)
            binding_declaration_row = index;
        if (!reference.flags.declare and @backingInt(reference.node_index) == bound_raw)
            bound_reference_row = index;
        if (!reference.flags.declare and reference.flags.write) write_symbol = @backingInt(reference.symbol_id);
    }
    const declaration_row = binding_declaration_row orelse return error.MissingHostileDeclaration;
    const reference_row = bound_reference_row orelse return error.MissingHostileReferenceRow;
    const other_symbol = if (bound_symbol == 0) @as(u32, 1) else @as(u32, 0);
    const other_binding_symbol = if (binding_symbol == 0) @as(u32, 1) else @as(u32, 0);
    if (other_symbol >= symbols.len) return error.MissingDistinctHostileSymbol;

    switch (mutation) {
        .missing_binding_id => symbol_ids[binding_raw] = null,
        .invalid_binding_id => symbol_ids[binding_raw] = @intCast(symbols.len),
        .missing_reference_id => symbol_ids[bound_raw] = null,
        .invalid_reference_id => symbol_ids[bound_raw] = @intCast(symbols.len),
        .missing_reference_row => _ = references.orderedRemove(reference_row),
        .duplicate_reference_row => try references.append(allocator, references.items[reference_row]),
        .wrong_reference_symbol => references.items[reference_row].symbol_id = @fromBackingInt(@intCast(other_symbol)),
        .stale_reference_node => references.items[reference_row].node_index = @fromBackingInt(literal_raw),
        .missing_declaration => _ = references.orderedRemove(declaration_row),
        .wrong_declaration_symbol => references.items[declaration_row].symbol_id = @fromBackingInt(@intCast(other_binding_symbol)),
        .invalid_reference_scope => references.items[reference_row].scope_id = .none,
        .missing_scope_owner => {
            var owners = scope_owner_map.iterator();
            const owner = owners.next() orelse return error.MissingHostileScopeOwner;
            _ = scope_owner_map.remove(owner.key_ptr.*);
        },
        .invalid_scope_owner => {
            var owners = scope_owner_map.iterator();
            const owner = owners.next() orelse return error.MissingHostileScopeOwner;
            scope_owner_map.getPtr(owner.key_ptr.*).?.* = @intCast(analyzer.scopes.items.len);
        },
        .wrong_reference_count => symbols[bound_symbol].reference_count +|= 1,
        .wrong_write_count => symbols[write_symbol orelse return error.MissingHostileWrite].write_count +|= 1,
        .missing_statement_index => references.items[reference_row].stmt_idx = SemanticReference.NO_STMT,
        .wrong_statement_index => references.items[reference_row].stmt_idx = if (references.items[reference_row].stmt_idx == 0) 1 else 0,
        .wrong_scope_statement_index => references.items[reference_row].scope_stmt_idx +|= 1,
    }

    var failure: MinifiedGraphGateFailure = .allocation;
    const retained = canRetainMinifiedSemanticGraph(
        allocator,
        &parser.ast,
        root,
        symbols,
        analyzer.scopes.items,
        references.items,
        symbol_ids,
        &analyzer.unresolved_references,
        &scope_owner_map,
        &failure,
    );
    return !retained and failure != .allocation;
}

fn shouldRecordPrepassExplicitGlobals(
    can_keep_semantic_graph: bool,
    ast: *const ast_mod.Ast,
    options: TransformOptions,
    flow_match_has_generated_globals: bool,
    has_lowered_object_spread: bool,
    has_lowered_exponentiation: bool,
    safe_builtin_worklet: bool,
    lowered_simple_static_class_field_global: bool,
) bool {
    // Identifier-valued defines such as `undefined` are explicit globals.
    // The retained graph must carry their sidecar so later linking cannot
    // resolve them to a same-spelled source binding.
    return flow_match_has_generated_globals or has_lowered_object_spread or has_lowered_exponentiation or
        safe_builtin_worklet or
        (can_keep_semantic_graph and define_mod.astUsesDefine(ast, options.define)) or
        lowered_simple_static_class_field_global;
}

fn isBuiltinWorkletPluginSet(plugins: anytype) bool {
    return plugins.len == 1 and std.mem.eql(u8, plugins[0].name, "reanimated-worklet");
}

test "worklet graph retention admits only the built-in plugin" {
    const Plugin = @import("../plugin.zig").Plugin;
    const built_in = [_]Plugin{.{ .name = "reanimated-worklet" }};
    const custom = [_]Plugin{.{ .name = "user-ast-plugin" }};
    const mixed = [_]Plugin{
        .{ .name = "reanimated-worklet" },
        .{ .name = "user-ast-plugin" },
    };

    try std.testing.expect(isBuiltinWorkletPluginSet(&built_in));
    try std.testing.expect(!isBuiltinWorkletPluginSet(&custom));
    try std.testing.expect(!isBuiltinWorkletPluginSet(&mixed));
    try std.testing.expect(!isBuiltinWorkletPluginSet(&.{}));
}

test "syntax minification retains only an exact semantic graph" {
    const Case = struct {
        source: []const u8,
        retain: bool,
    };
    const cases = [_]Case{
        .{ .source = "function read(input) { return input + 1; }", .retain = true },
        .{ .source = "function read(input) { return input + (2 * 3); }", .retain = true },
        .{ .source = "function read(input) { if (true) { return input; } }", .retain = false },
        .{ .source = "function read(input) { const one = 1; return one; }", .retain = false },
        .{ .source = "function read(input) { const dead = 1; return 2; }", .retain = false },
        .{ .source = "function read(input) { return true ? input : 0; }", .retain = false },
        .{ .source = "function read(input) { return false ? 0 : input; }", .retain = false },
        .{ .source = "function read(input) { return false && input; }", .retain = false },
        .{ .source = "function read(input) { return true || input; }", .retain = false },
        .{ .source = "function read(input) { if (false) { 1; } return input; }", .retain = false },
        .{ .source = "const ONE = 1; function read() { return ONE; }", .retain = false },
        .{ .source = "function read(input) { const value = input + 1; return value; }", .retain = true },
        .{ .source = "function read(input) { const one = 1; const two = one; return two; }", .retain = false },
        .{ .source = "function read(input) { if (false) use(input); return 0; }", .retain = false },
        .{ .source = "import { value } from './values.js'; function read() { return value; }", .retain = true },
        .{ .source = "import { value as local } from './values.js'; function read() { return local; }", .retain = true },
        .{ .source = "import value from './values.js'; function read() { return value; }", .retain = true },
        .{ .source = "import * as values from './values.js'; function read() { return values.value; }", .retain = true },
    };

    for (cases) |case| {
        const retained = try syntaxMinifyGraphRetainableForTest(case.source);
        try std.testing.expectEqual(case.retain, retained);
    }
}

test "import binding graph gate requires exact local declaration anchors" {
    inline for (std.meta.tags(ImportDeclarationGraphMutation)) |mutation| {
        const retained = try importDeclarationGraphRetainableForTest(mutation);
        try std.testing.expectEqual(mutation == .none, retained);
    }
}

test "syntax minification repairs statement coordinates without changing identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const seed = 1; function read(input) { const alias = input; { const nested = alias; return seed + nested; } }");
    defer scanner.deinit();
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    defer parser.deinit();
    const root = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    defer analyzer.deinit();
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();

    for (analyzer.references.items) |reference| {
        try std.testing.expectEqual(SemanticReference.NO_STMT, reference.stmt_idx);
        try std.testing.expectEqual(SemanticReference.NO_STMT, reference.scope_stmt_idx);
    }
    var failure: MinifiedGraphGateFailure = .allocation;
    try std.testing.expect(!canRetainMinifiedSemanticGraph(
        allocator,
        &parser.ast,
        root,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.references.items,
        analyzer.symbol_ids.items,
        &analyzer.unresolved_references,
        &analyzer.scope_owner_map,
        &failure,
    ));
    try std.testing.expectEqual(MinifiedGraphGateFailure.invalid_statement_context, failure);

    const updated = (try reindexMinifiedSemanticReferences(
        allocator,
        &parser.ast,
        root,
        analyzer.references.items,
    )) orelse return error.CouldNotReindexStatementContexts;
    try std.testing.expectEqual(analyzer.references.items.len, updated.len);
    var statement_oracle = SemanticAnalyzer.init(allocator, &parser.ast);
    defer statement_oracle.deinit();
    statement_oracle.is_strict_mode = parser.is_strict_mode;
    statement_oracle.is_module = parser.is_module;
    statement_oracle.enable_stmt_info = true;
    statement_oracle.enable_exact_declaration_anchors = true;
    try statement_oracle.analyze();
    for (analyzer.references.items, updated) |before, after| {
        try std.testing.expectEqual(before.symbol_id, after.symbol_id);
        try std.testing.expectEqual(before.scope_id, after.scope_id);
        try std.testing.expectEqual(before.flags, after.flags);
        try std.testing.expect(after.stmt_idx != SemanticReference.NO_STMT);
        try std.testing.expect(after.scope_stmt_idx != SemanticReference.NO_STMT);

        var expected: ?SemanticReference = null;
        for (statement_oracle.references.items) |candidate| {
            if (candidate.flags.declare != before.flags.declare or candidate.symbol_id != before.symbol_id)
                continue;
            const same_node = if (before.flags.declare)
                candidate.declaration_node_index == before.declaration_node_index
            else
                candidate.node_index == before.node_index;
            if (!same_node) continue;
            expected = candidate;
            break;
        }
        const expected_reference = expected orelse return error.MissingStatementOracleReference;
        try std.testing.expectEqual(expected_reference.stmt_idx, after.stmt_idx);
        try std.testing.expectEqual(expected_reference.scope_stmt_idx, after.scope_stmt_idx);
    }
    try std.testing.expect(canRetainMinifiedSemanticGraph(
        allocator,
        &parser.ast,
        root,
        analyzer.symbols.items,
        analyzer.scopes.items,
        updated,
        analyzer.symbol_ids.items,
        &analyzer.unresolved_references,
        &analyzer.scope_owner_map,
        null,
    ));
}

test "syntax minify graph gate rejects eighteen hostile identity and statement corruptions" {
    inline for (std.meta.tags(MinifiedGraphMutation)) |mutation| {
        const rejected = try minifiedGraphMutationIsRejected(mutation);
        if (!rejected) std.debug.print("minify graph mutation accepted: {s}\n", .{@tagName(mutation)});
        try std.testing.expect(rejected);
    }
}

test "primitive defines retain only an exact local reference graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "const flag = 1; function read() { return flag; }";

    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    defer parser.deinit();
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    defer analyzer.deinit();
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    try analyzer.analyze();

    var module = Module.init(@fromBackingInt(@as(u32, 0)), "input.js");
    module.source = source;
    module.ast = parser.ast;
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

    const Plugin = @import("../plugin.zig").Plugin;
    const test_context = .{
        .allocator = allocator,
        .flow = false,
        .worklet_transform = false,
        .plugins = &[_]Plugin{},
        .styled_components = false,
        .emotion = false,
    };
    const primitive_defines = [_]define_mod.DefineEntry{.{ .key = "flag", .value = "false" }};
    const unsupported_defines = [_]define_mod.DefineEntry{.{ .key = "flag", .value = "globalThis.value" }};
    var allow_super_get = false;
    var allow_super_set = false;
    const primitive_options: TransformOptions = .{ .strip_types = true, .define = &primitive_defines };
    const primitive_graph_retained = canKeepPrepassSemanticGraph(
        &test_context,
        &module,
        primitive_options,
        &[_]Plugin{},
        &allow_super_get,
        &allow_super_set,
        null,
    );
    try std.testing.expect(primitive_graph_retained);
    try std.testing.expect(shouldRecordPrepassExplicitGlobals(
        primitive_graph_retained,
        &parser.ast,
        primitive_options,
        false,
        false,
        false,
        false,
        false,
    ));
    const unsupported_graph_retained = canKeepPrepassSemanticGraph(
        &test_context,
        &module,
        .{ .strip_types = true, .define = &unsupported_defines },
        &[_]Plugin{},
        &allow_super_get,
        &allow_super_set,
        null,
    );
    try std.testing.expect(!unsupported_graph_retained);
    try std.testing.expect(!shouldRecordPrepassExplicitGlobals(
        unsupported_graph_retained,
        &parser.ast,
        .{ .strip_types = true, .define = &unsupported_defines },
        false,
        false,
        false,
        false,
        false,
    ));
}

test "prepass records generated globals on fallback and gates define globals on retention" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const flag = 1; console.log(flag);");
    defer scanner.deinit();
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    defer parser.deinit();
    _ = try parser.parse();

    const defines = [_]define_mod.DefineEntry{.{ .key = "flag", .value = "false" }};
    const options_with_define: TransformOptions = .{ .define = &defines };
    const Case = struct {
        name: []const u8,
        can_keep: bool = false,
        flow: bool = false,
        object_spread: bool = false,
        exponentiation: bool = false,
        worklet: bool = false,
        static_class: bool = false,
        options: TransformOptions = .{},
        expected: bool,
    };
    const cases = [_]Case{
        .{ .name = "no generated global", .expected = false },
        .{ .name = "object spread global survives reanalysis", .object_spread = true, .expected = true },
        .{ .name = "exponentiation global survives reanalysis", .exponentiation = true, .expected = true },
        .{ .name = "Flow helper global survives reanalysis", .flow = true, .expected = true },
        .{ .name = "built-in worklet global survives reanalysis", .worklet = true, .expected = true },
        .{ .name = "downlevel class global survives reanalysis", .static_class = true, .expected = true },
        .{ .name = "multiple lowerer globals survive reanalysis", .object_spread = true, .exponentiation = true, .expected = true },
        .{ .name = "retained define records its explicit global", .can_keep = true, .options = options_with_define, .expected = true },
        .{ .name = "reanalyzed define leaves global discovery to analyzer", .options = options_with_define, .expected = false },
        .{ .name = "retained graph without generated globals adds no sidecar", .can_keep = true, .expected = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            shouldRecordPrepassExplicitGlobals(
                case.can_keep,
                &parser.ast,
                case.options,
                case.flow,
                case.object_spread,
                case.exponentiation,
                case.worklet,
                case.static_class,
            ),
        );
    }
}

const ConsolePreflightMutation = enum {
    none,
    empty_scope_map,
    truncated_symbol_id_map,
    missing_symbol_id,
    invalid_symbol_id,
    import_binding,
    duplicate_reference,
    missing_reference,
    mismatched_reference_symbol,
    invalid_reference_scope,
    wrong_valid_reference_scope,
    missing_scope_owner,
    wrong_scope_owner,
    invalid_binding_scope,
    out_of_range_binding_scope,
    synthetic_binding,
    truncated_argument_slice,
    invalid_argument_node,
    remove_unresolved_reference,
    unexpected_symbol_id,
    non_string_computed_property,
};

fn canRetainConsoleDropForTest(source: []const u8, mutation: ConsolePreflightMutation) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    defer analyzer.deinit();
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    try analyzer.analyze();

    var target_raw: ?u32 = null;
    var target_call_extra: ?usize = null;
    var target_computed_property: ?usize = null;
    for (try ast_walk.collectReachableNodeIndices(allocator, &parser.ast)) |raw| {
        const statement = parser.ast.nodes.items[raw];
        if (!drop_mod.isConsoleCallInAst(&parser.ast, statement)) continue;
        const shape = simpleConsoleDropShape(&parser.ast, statement) orelse return false;
        target_raw = shape.object_reference;
        const call_idx = statement.data.unary.operand;
        target_call_extra = parser.ast.getNode(call_idx).data.extra;
        const callee_raw = parser.ast.extra_data.items[target_call_extra.?];
        const callee = parser.ast.nodes.items[callee_raw];
        if (callee.tag == .computed_member_expression) {
            target_computed_property = parser.ast.extra_data.items[callee.data.extra + 1];
        }
        break;
    }
    var target_reference_index: ?usize = null;
    if (target_raw) |raw| {
        for (analyzer.references.items, 0..) |reference, index| {
            if (!reference.node_index.isNone() and @backingInt(reference.node_index) == raw) {
                target_reference_index = index;
            }
        }
    }
    if (target_raw) |raw| {
        switch (mutation) {
            .none => {},
            .empty_scope_map => analyzer.scopes.items.len = 0,
            .truncated_symbol_id_map => analyzer.symbol_ids.items.len = raw,
            .missing_symbol_id => {
                if (raw >= analyzer.symbol_ids.items.len) return error.MissingTargetSymbol;
                analyzer.symbol_ids.items[raw] = null;
            },
            .invalid_symbol_id => {
                if (raw >= analyzer.symbol_ids.items.len) return error.MissingTargetSymbol;
                analyzer.symbol_ids.items[raw] = @intCast(analyzer.symbols.items.len);
            },
            .import_binding => {
                const symbol_id = if (raw < analyzer.symbol_ids.items.len)
                    analyzer.symbol_ids.items[raw] orelse return error.MissingTargetSymbol
                else
                    return error.MissingTargetSymbol;
                analyzer.symbols.items[symbol_id].kind = .import_binding;
            },
            .duplicate_reference => {
                const index = target_reference_index orelse return error.MissingTargetReference;
                const reference = analyzer.references.items[index];
                try analyzer.references.append(allocator, reference);
            },
            .missing_reference => {
                const index = target_reference_index orelse return error.MissingTargetReference;
                _ = analyzer.references.orderedRemove(index);
            },
            .mismatched_reference_symbol => {
                const index = target_reference_index orelse return error.MissingTargetReference;
                const expected = @backingInt(analyzer.references.items[index].symbol_id);
                var replacement: ?u32 = null;
                for (analyzer.symbols.items, 0..) |_, candidate| {
                    if (candidate != expected) {
                        replacement = @intCast(candidate);
                        break;
                    }
                }
                analyzer.references.items[index].symbol_id = @fromBackingInt(
                    replacement orelse return error.MissingReplacementSymbol,
                );
            },
            .invalid_reference_scope => {
                const index = target_reference_index orelse return error.MissingTargetReference;
                analyzer.references.items[index].scope_id = @fromBackingInt(@intCast(analyzer.scopes.items.len + 1));
            },
            .wrong_valid_reference_scope => {
                const index = target_reference_index orelse return error.MissingTargetReference;
                const expected = @backingInt(analyzer.references.items[index].scope_id);
                var replacement: ?u32 = null;
                for (analyzer.scopes.items, 0..) |_, candidate| {
                    if (candidate != expected) {
                        replacement = @intCast(candidate);
                        break;
                    }
                }
                analyzer.references.items[index].scope_id = @fromBackingInt(
                    replacement orelse return error.MissingReplacementScope,
                );
            },
            .missing_scope_owner => {
                for (parser.ast.nodes.items, 0..) |node, raw_node| {
                    if (node.tag == .program) {
                        _ = analyzer.scope_owner_map.remove(@intCast(raw_node));
                        break;
                    }
                }
            },
            .wrong_scope_owner => {
                for (parser.ast.nodes.items, 0..) |node, raw_node| {
                    if (node.tag == .program) {
                        try analyzer.scope_owner_map.put(
                            allocator,
                            @intCast(raw_node),
                            @intCast(analyzer.scopes.items.len + 1),
                        );
                        break;
                    }
                }
            },
            .invalid_binding_scope => {
                const symbol_id = analyzer.symbol_ids.items[raw] orelse return error.MissingTargetSymbol;
                analyzer.symbols.items[symbol_id].scope_id = .none;
            },
            .out_of_range_binding_scope => {
                const symbol_id = analyzer.symbol_ids.items[raw] orelse return error.MissingTargetSymbol;
                analyzer.symbols.items[symbol_id].scope_id = @fromBackingInt(@intCast(analyzer.scopes.items.len + 1));
            },
            .synthetic_binding => {
                const symbol_id = analyzer.symbol_ids.items[raw] orelse return error.MissingTargetSymbol;
                analyzer.symbols.items[symbol_id].synthetic_kind = .runtime_helper_import;
            },
            .truncated_argument_slice => {
                const extra = target_call_extra orelse return error.MissingTargetCall;
                parser.ast.extra_data.items[extra + 1] = @intCast(parser.ast.extra_data.items.len);
            },
            .invalid_argument_node => {
                const extra = target_call_extra orelse return error.MissingTargetCall;
                const args_start = parser.ast.extra_data.items[extra + 1];
                if (args_start >= parser.ast.extra_data.items.len) return error.MissingTargetArgument;
                parser.ast.extra_data.items[args_start] = @intCast(parser.ast.nodes.items.len);
            },
            .remove_unresolved_reference => {
                if (!analyzer.unresolved_references.remove("console")) return error.MissingUnresolvedReference;
            },
            .unexpected_symbol_id => {
                var sentinel_symbol: ?u32 = null;
                for (analyzer.symbols.items, 0..) |symbol, symbol_idx| {
                    if (std.mem.eql(u8, parser.ast.getText(symbol.name), "sentinel")) {
                        sentinel_symbol = @intCast(symbol_idx);
                        break;
                    }
                }
                const symbol_id = sentinel_symbol orelse return error.MissingTargetSymbol;
                if (raw >= analyzer.symbol_ids.items.len) return error.MissingTargetSymbol;
                analyzer.symbol_ids.items[raw] = symbol_id;
            },
            .non_string_computed_property => {
                const property_raw = target_computed_property orelse return error.MissingComputedProperty;
                parser.ast.nodes.items[property_raw].tag = .identifier_reference;
            },
        }
    } else if (mutation != .none) {
        return false;
    }

    const semantic = ModuleSemanticData{
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
    return canRetainGraphForSimpleConsoleDrops(allocator, &parser.ast, &semantic);
}

const SimpleConsoleDropTestShape = struct {
    is_console_call: bool,
    shape: ?SimpleConsoleDrop,
};

fn simpleConsoleDropShapeForTest(source: []const u8) !SimpleConsoleDropTestShape {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    for (parser.ast.nodes.items) |node| {
        if (node.tag == .expression_statement) return .{
            .is_console_call = drop_mod.isConsoleCallInAst(&parser.ast, node),
            .shape = simpleConsoleDropShape(&parser.ast, node),
        };
    }
    return .{ .is_console_call = false, .shape = null };
}

test "simple drop-console shape accepts arbitrary argument ASTs and rejects dynamic callees" {
    const static = try simpleConsoleDropShapeForTest(
        "const console = {}; console[`log`](`ok`);",
    );
    try std.testing.expect(static.is_console_call);
    try std.testing.expect(static.shape != null);

    const dynamic_key = try simpleConsoleDropShapeForTest(
        "const console = {}; console[`log${suffix}`](\"ok\");",
    );
    try std.testing.expect(!dynamic_key.is_console_call);
    try std.testing.expect(dynamic_key.shape == null);

    for ([_][]const u8{
        "const console = {}; console?.[\"log\"](\"ok\");",
        "const console = {}; console[\"log\"]?.(\"ok\");",
    }) |source| {
        const optional = try simpleConsoleDropShapeForTest(source);
        try std.testing.expect(optional.shape == null);
    }

    const primitive_arguments = [_][]const u8{
        "console.log(`value ${1}`);",
        "console.log(`value ${'text'}`);",
        "console.log(`value ${true}`);",
        "console.log(`value ${false}`);",
        "console.log(`value ${null}`);",
        "console.log(`value ${1n}`);",
        "console.log(`${1} and ${'two'}`);",
    };
    for (primitive_arguments) |source| {
        const retained = try simpleConsoleDropShapeForTest(source);
        try std.testing.expect(retained.is_console_call);
        try std.testing.expect(retained.shape != null);
    }
    for ([_][]const u8{
        "console.log(value);",
        "console.log(first, second);",
        "console[`log`](value, `literal`);",
    }) |source| {
        const retained = try simpleConsoleDropShapeForTest(source);
        try std.testing.expect(retained.is_console_call);
        try std.testing.expect(retained.shape != null);
    }

    // Argument semantics are intentionally deferred until after the semantic
    // editor removes the call; exact post-edit graph validation decides whether
    // the existing graph can be kept or analysis must be refreshed.
    const dynamic_arguments = [_][]const u8{
        "const value = 1; console.log(`value ${value}`);",
        "console.log(`value ${getValue()}`);",
        "let value = 0; console.log(`value ${value = 1}`);",
        "let value = 0; console.log(`value ${++value}`);",
        "console.log(`value ${{ value: 1 }}`);",
        "console.log(`value ${[1]}`);",
        "console.log(`value ${/x/}`);",
        "console.log(`value ${tag`nested`}`);",
        "const object = {}; console.log(`value ${object + 1}`);",
        "console.log(`value ${condition ? getValue() : 2}`);",
    };
    for (dynamic_arguments) |source| {
        const dynamic = try simpleConsoleDropShapeForTest(source);
        try std.testing.expect(dynamic.is_console_call);
        try std.testing.expect(dynamic.shape != null);
    }
}

test "simple drop-console preflight validates the exact callee, not removed arguments" {
    const source = "const console = {}; const other = 1; console.log(\"ok\");";
    const local_argument_source = "const console = {}; const other = 1; console.log(other);";
    const multiple_local_arguments_source = "const console = {}; const first = 1; const second = 2; console.log(first, second);";
    const global_source = "console.log(\"ok\");";
    const computed_source = "const console = {}; const other = 1; console[\"log\"](\"ok\");";
    const computed_global_source = "console['log'](\"ok\");";
    const template_key_source = "const console = {}; console[`log`](`ok`);";
    const template_argument_source = "console.log(`ok`);";
    const imported_argument_source = "import { other } from './values.js'; console.log(other);";
    const hostile_identifier_arguments = [_][]const u8{
        "console.log(notDeclared);",
        "import { value } from './values.js'; console.log(value);",
        "const record = {}; console.log(record.value);",
        "function read() { return 1; } console.log(read());",
        "let value = 1; console.log(value = 2);",
        "let value = 1; console.log(++value);",
        "const values = []; console.log(...values);",
        "const value = {}; console.log(value?.child);",
        "const value = 1; console.log((value, 1));",
        "const value = 1; console.log({ value });",
    };
    for (hostile_identifier_arguments) |hostile_source| {
        try std.testing.expect(try canRetainConsoleDropForTest(hostile_source, .none));
    }
    const unsafe_sources = [_][]const u8{
        "import console from 'pkg'; console.log(\"ok\");",
        "const console = {}; console[key](\"ok\");",
        "const console = {}; console[getKey()](\"ok\");",
        "const console = {}; console[Symbol.iterator](\"ok\");",
        "const console = {}; console[0](\"ok\");",
        "const console = {}; console[`lo${g}`](\"ok\");",
        "const console = {}; console[`log${suffix}`](\"ok\");",
        "const console = {}; console[`${prefix}log`](\"ok\");",
        "const console = {}; console[`log${getKey()}`](\"ok\");",
        "const console = {}; console[`log` + suffix](\"ok\");",
        "console[`log${suffix}`](\"ok\");",
        "const console = {}; console?.[\"log\"](\"ok\");",
        "const console = {}; console[\"log\"]?.(\"ok\");",
        "import console from 'pkg'; console[\"log\"](\"ok\");",
        "const console = {}; console[\"log\"].call(console, \"ok\");",
        "const console = {}; console.log.call(console, \"ok\");",
    };
    for (unsafe_sources) |unsafe_source| {
        try std.testing.expect(!try canRetainConsoleDropForTest(unsafe_source, .none));
    }

    const mutations = [_]ConsolePreflightMutation{
        .empty_scope_map,
        .truncated_symbol_id_map,
        .missing_symbol_id,
        .invalid_symbol_id,
        .import_binding,
        .duplicate_reference,
        .missing_reference,
        .mismatched_reference_symbol,
        .invalid_reference_scope,
        .wrong_valid_reference_scope,
        .missing_scope_owner,
        .wrong_scope_owner,
        .invalid_binding_scope,
        .out_of_range_binding_scope,
        .synthetic_binding,
        .truncated_argument_slice,
        .invalid_argument_node,
        .remove_unresolved_reference,
        .unexpected_symbol_id,
        .non_string_computed_property,
    };
    for (mutations) |mutation| {
        const mutation_source = switch (mutation) {
            .wrong_valid_reference_scope => "const console = {}; function read() { console.log(\"ok\"); }",
            .remove_unresolved_reference, .unexpected_symbol_id => "const sentinel = 1; console.log(\"ok\");",
            .non_string_computed_property => computed_source,
            else => source,
        };
        try std.testing.expect(!try canRetainConsoleDropForTest(mutation_source, mutation));
    }
    try std.testing.expect(!try canRetainConsoleDropForTest("const value = 1;", .none));
    try std.testing.expect(try canRetainConsoleDropForTest(global_source, .none));
    try std.testing.expect(try canRetainConsoleDropForTest(local_argument_source, .none));
    try std.testing.expect(try canRetainConsoleDropForTest(multiple_local_arguments_source, .none));
    try std.testing.expect(try canRetainConsoleDropForTest(computed_source, .none));
    try std.testing.expect(try canRetainConsoleDropForTest(computed_global_source, .none));
    try std.testing.expect(try canRetainConsoleDropForTest(template_key_source, .none));
    try std.testing.expect(try canRetainConsoleDropForTest(template_argument_source, .none));
    try std.testing.expect(try canRetainConsoleDropForTest(imported_argument_source, .none));
    try std.testing.expect(try canRetainConsoleDropForTest(
        "const console = {}; console[`log`](`ok`, 1, true, null, 1n, /x/);",
        .none,
    ));

    try std.testing.expect(try canRetainConsoleDropForTest(
        "const console = {}; console.log(\"ok\", 1, true, null, 1n, /x/);",
        .none,
    ));

    for (mutations) |mutation| {
        const mutation_source = switch (mutation) {
            .wrong_valid_reference_scope => "const console = {}; function read() { console[\"log\"](\"ok\"); }",
            .remove_unresolved_reference, .unexpected_symbol_id => "const sentinel = 1; console['log'](\"ok\");",
            else => computed_source,
        };
        try std.testing.expect(!try canRetainConsoleDropForTest(mutation_source, mutation));
    }
}

test "simple drop-console graph is retained by the full prepass gate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "import { value } from './values.js'; console.log(value);";

    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    defer parser.deinit();
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    defer analyzer.deinit();
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    try analyzer.analyze();

    var module = Module.init(@fromBackingInt(@as(u32, 0)), "input.js");
    module.source = source;
    module.module_type = .js;
    module.ast = parser.ast;
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

    const Plugin = @import("../plugin.zig").Plugin;
    const test_context = .{
        .allocator = allocator,
        .flow = false,
        .worklet_transform = false,
        .plugins = &[_]Plugin{},
        .styled_components = false,
        .emotion = false,
    };
    var allow_super_get = false;
    var allow_super_set = false;
    var retained_simple_console_drops = false;
    const can_keep = canKeepPrepassSemanticGraph(
        &test_context,
        &module,
        .{ .strip_types = true, .drop_console = true },
        &[_]Plugin{},
        &allow_super_get,
        &allow_super_set,
        &retained_simple_console_drops,
    );
    try std.testing.expect(retained_simple_console_drops);
    try std.testing.expect(can_keep);
    const import_ast = &(module.ast orelse unreachable);
    const import_options: TransformOptions = .{ .strip_types = true, .drop_console = true };
    try std.testing.expect(canRetainPlainJavaScriptImportsForConsoleDrop(
        &test_context,
        &module,
        import_ast,
        import_options,
        true,
    ));
    try std.testing.expect(!canRetainPlainJavaScriptImportsForConsoleDrop(
        &test_context,
        &module,
        import_ast,
        import_options,
        false,
    ));
    var typescript_module = module;
    typescript_module.module_type = .ts;
    try std.testing.expect(!canRetainPlainJavaScriptImportsForConsoleDrop(
        &test_context,
        &typescript_module,
        import_ast,
        import_options,
        true,
    ));
    const flow_context = .{
        .allocator = allocator,
        .flow = true,
        .worklet_transform = false,
        .plugins = &[_]Plugin{},
        .styled_components = false,
        .emotion = false,
    };
    try std.testing.expect(!canRetainPlainJavaScriptImportsForConsoleDrop(
        &flow_context,
        &module,
        import_ast,
        import_options,
        true,
    ));
    const worklet_context = .{
        .allocator = allocator,
        .flow = false,
        .worklet_transform = true,
        .plugins = &[_]Plugin{},
        .styled_components = false,
        .emotion = false,
    };
    try std.testing.expect(!canRetainPlainJavaScriptImportsForConsoleDrop(
        &worklet_context,
        &module,
        import_ast,
        import_options,
        true,
    ));
    var flow_path_module = module;
    flow_path_module.path = "input.js.flow";
    try std.testing.expect(!canRetainPlainJavaScriptImportsForConsoleDrop(
        &test_context,
        &flow_path_module,
        import_ast,
        import_options,
        true,
    ));
    var unsupported_options = import_options;
    unsupported_options.unsupported.class = true;
    try std.testing.expect(!canRetainPlainJavaScriptImportsForConsoleDrop(
        &test_context,
        &module,
        import_ast,
        unsupported_options,
        true,
    ));
    var minified_options = import_options;
    minified_options.minify_syntax = true;
    try std.testing.expect(!canRetainPlainJavaScriptImportsForConsoleDrop(
        &test_context,
        &module,
        import_ast,
        minified_options,
        true,
    ));
    var jsx_ast = import_ast.*;
    jsx_ast.has_jsx = true;
    try std.testing.expect(!canRetainPlainJavaScriptImportsForConsoleDrop(
        &test_context,
        &module,
        &jsx_ast,
        import_options,
        true,
    ));
    var decorator_ast = import_ast.*;
    decorator_ast.has_decorator = true;
    try std.testing.expect(!canRetainPlainJavaScriptImportsForConsoleDrop(
        &test_context,
        &module,
        &decorator_ast,
        import_options,
        true,
    ));
    var tla_module = module;
    tla_module.uses_top_level_await = true;
    try std.testing.expect(!canRetainPlainJavaScriptImportsForConsoleDrop(
        &test_context,
        &tla_module,
        import_ast,
        import_options,
        true,
    ));
    var debugger_options = import_options;
    debugger_options.drop_debugger = true;
    try std.testing.expect(!canRetainPlainJavaScriptImportsForConsoleDrop(
        &test_context,
        &module,
        import_ast,
        debugger_options,
        true,
    ));
    var whitespace_options = import_options;
    whitespace_options.minify_whitespace = true;
    try std.testing.expect(!canRetainPlainJavaScriptImportsForConsoleDrop(
        &test_context,
        &module,
        import_ast,
        whitespace_options,
        true,
    ));
    const custom_plugins = [_]Plugin{.{ .name = "user-plugin" }};
    const plugin_context = .{
        .allocator = allocator,
        .flow = false,
        .worklet_transform = false,
        .plugins = &custom_plugins,
        .styled_components = false,
        .emotion = false,
    };
    try std.testing.expect(!canRetainPlainJavaScriptImportsForConsoleDrop(
        &plugin_context,
        &module,
        import_ast,
        import_options,
        true,
    ));
    var plugin_options = import_options;
    plugin_options.plugins = &custom_plugins;
    try std.testing.expect(!canRetainPlainJavaScriptImportsForConsoleDrop(
        &test_context,
        &module,
        import_ast,
        plugin_options,
        true,
    ));
}

const RetainedTlaTestCorruption = enum {
    none,
    missing_owner_map,
    out_of_range_scope_owner,
    missing_scopes,
};

fn hasTopLevelAwaitForTest(source: []const u8, corruption: RetainedTlaTestCorruption) !?bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    defer parser.deinit();
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    defer analyzer.deinit();
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    try analyzer.analyze();
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer scope_owner_map.deinit(allocator);
    if (corruption != .missing_owner_map) {
        scope_owner_map = try analyzer.scope_owner_map.clone(allocator);
    }
    if (corruption == .out_of_range_scope_owner) {
        for (parser.ast.nodes.items, 0..) |node, index| {
            if (node.tag != .await_expression and node.tag != .for_await_of_statement) continue;
            try scope_owner_map.put(allocator, @intCast(index), @intCast(analyzer.scopes.items.len));
            break;
        }
    }
    return hasTopLevelAwaitInRetainedGraph(
        allocator,
        &parser.ast,
        if (corruption == .missing_scopes) &.{} else analyzer.scopes.items,
        &scope_owner_map,
    );
}

test "retained graph TLA scan excludes function awaits and keeps module awaits" {
    const cases = .{
        .{ .source = "await Promise.resolve(1);", .expected = true },
        .{ .source = "{ await Promise.resolve(1); }", .expected = true },
        .{ .source = "for await (const value of values) { void value; }", .expected = true },
        .{ .source = "async function read() { await Promise.resolve(1); }", .expected = false },
        .{ .source = "async function read() { { await Promise.resolve(1); } }", .expected = false },
        .{ .source = "async function read() { for await (const value of values) { void value; } }", .expected = false },
    };
    inline for (cases) |case| {
        try std.testing.expectEqual(case.expected, (try hasTopLevelAwaitForTest(case.source, .none)).?);
    }
}

test "retained graph TLA scan rejects incomplete scope evidence" {
    try std.testing.expect((try hasTopLevelAwaitForTest("await Promise.resolve(1);", .missing_owner_map)) == null);
    try std.testing.expect((try hasTopLevelAwaitForTest("await Promise.resolve(1);", .out_of_range_scope_owner)) == null);
    try std.testing.expect((try hasTopLevelAwaitForTest("await Promise.resolve(1);", .missing_scopes)) == null);
}

fn refreshRetainedModuleTlaForTest(source: []const u8, initial_self_tla: bool) !?bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    defer parser.deinit();
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    defer analyzer.deinit();
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    try analyzer.analyze();

    var module = Module.init(@fromBackingInt(@as(u32, 0)), "input.mjs");
    module.ast = parser.ast;
    module.self_uses_top_level_await = initial_self_tla;
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
    if (!refreshRetainedModuleTopLevelAwait(allocator, &parser.ast, &module)) return null;
    return module.self_uses_top_level_await;
}

test "retained graph refreshes only module-local TLA metadata" {
    try std.testing.expect(!(try refreshRetainedModuleTlaForTest("console.log('ok');", true)).?);
    try std.testing.expect((try refreshRetainedModuleTlaForTest(
        "for await (const value of values) { void value; }",
        false,
    )).?);
    try std.testing.expect(!(try refreshRetainedModuleTlaForTest(
        "async function read() { await Promise.resolve(1); }",
        true,
    )).?);
}

fn canRetainDroppedLabelTlaForTest(unsupported_top_level_await: bool) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "DEV: await Promise.resolve(); console.log('ok');";

    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    defer parser.deinit();
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    defer analyzer.deinit();
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    try analyzer.analyze();

    var module = Module.init(@fromBackingInt(@as(u32, 0)), "input.mjs");
    module.source = source;
    module.module_type = .js;
    module.uses_top_level_await = analyzer.has_top_level_await;
    module.self_uses_top_level_await = analyzer.has_top_level_await;
    module.ast = parser.ast;
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

    const Plugin = @import("../plugin.zig").Plugin;
    const test_context = .{
        .allocator = allocator,
        .flow = false,
        .worklet_transform = false,
        .plugins = &[_]Plugin{},
        .styled_components = false,
        .emotion = false,
    };
    const labels = [_][]const u8{"DEV"};
    var options: TransformOptions = .{ .strip_types = true, .drop_labels = &labels };
    options.unsupported.top_level_await = unsupported_top_level_await;
    var allow_super_get = false;
    var allow_super_set = false;
    return canKeepPrepassSemanticGraph(
        &test_context,
        &module,
        options,
        &[_]Plugin{},
        &allow_super_get,
        &allow_super_set,
        null,
    );
}

test "drop-label TLA retains the graph only for native TLA output" {
    try std.testing.expect(try canRetainDroppedLabelTlaForTest(false));
    try std.testing.expect(!try canRetainDroppedLabelTlaForTest(true));
}

test "TLA refresh is limited to retained edits that can remove module await" {
    try std.testing.expect(shouldRefreshRetainedModuleTopLevelAwait(true, false, true, true));
    try std.testing.expect(shouldRefreshRetainedModuleTopLevelAwait(true, true, false, true));
    try std.testing.expect(!shouldRefreshRetainedModuleTopLevelAwait(true, false, false, true));
    try std.testing.expect(!shouldRefreshRetainedModuleTopLevelAwait(false, false, true, true));
    try std.testing.expect(!shouldRefreshRetainedModuleTopLevelAwait(true, false, true, false));
}

test "drop-label source scan recognizes only configured labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "DEV: await Promise.resolve();");
    defer scanner.deinit();
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    defer parser.deinit();
    _ = try parser.parse();
    const configured_labels = [_][]const u8{"DEV"};
    const other_labels = [_][]const u8{"TEST"};
    try std.testing.expect(hasDroppedLabeledStatement(&parser.ast, &configured_labels));
    try std.testing.expect(!hasDroppedLabeledStatement(&parser.ast, &other_labels));
}

const DefinePreflightMutation = enum {
    none,
    truncated_symbol_id_map,
    missing_symbol_id,
    invalid_symbol_id,
    import_binding,
    duplicate_reference,
    missing_reference,
    mismatched_reference_symbol,
    invalid_reference_scope,
    invalid_binding_scope,
    out_of_range_binding_scope,
    synthetic_binding,
};

fn canRetainSimpleDefineForTest(
    source: []const u8,
    key: []const u8,
    value: []const u8,
    mutation: DefinePreflightMutation,
) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    defer parser.deinit();
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    defer analyzer.deinit();
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    try analyzer.analyze();

    const defines = [_]define_mod.DefineEntry{.{ .key = key, .value = value }};
    var target_raw: ?usize = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (define_mod.matchedDefineValue(&parser.ast, node, &defines) != null) {
            target_raw = raw;
            break;
        }
    }
    const raw = target_raw orelse return false;

    var target_reference_index: ?usize = null;
    for (analyzer.references.items, 0..) |reference, index| {
        if (!reference.node_index.isNone() and @backingInt(reference.node_index) == raw) {
            target_reference_index = index;
            break;
        }
    }
    switch (mutation) {
        .none => {},
        .truncated_symbol_id_map => analyzer.symbol_ids.items.len = raw,
        .missing_symbol_id => {
            analyzer.symbol_ids.items[raw] = null;
            const index = target_reference_index orelse return error.MissingTargetReference;
            analyzer.references.items[index].symbol_id = @fromBackingInt(0);
        },
        .invalid_symbol_id => {
            const invalid_id: u32 = @intCast(analyzer.symbols.items.len);
            analyzer.symbol_ids.items[raw] = invalid_id;
            const index = target_reference_index orelse return error.MissingTargetReference;
            analyzer.references.items[index].symbol_id = @fromBackingInt(invalid_id);
        },
        .import_binding => {
            const symbol_id = analyzer.symbol_ids.items[raw] orelse return error.MissingTargetSymbol;
            analyzer.symbols.items[symbol_id].kind = .import_binding;
        },
        .duplicate_reference => {
            const index = target_reference_index orelse return error.MissingTargetReference;
            const reference = analyzer.references.items[index];
            try analyzer.references.append(allocator, reference);
        },
        .missing_reference => {
            const index = target_reference_index orelse return error.MissingTargetReference;
            _ = analyzer.references.orderedRemove(index);
        },
        .mismatched_reference_symbol => {
            const index = target_reference_index orelse return error.MissingTargetReference;
            const expected = @backingInt(analyzer.references.items[index].symbol_id);
            var replacement: ?u32 = null;
            for (analyzer.symbols.items, 0..) |_, candidate| {
                if (candidate != expected) {
                    replacement = @intCast(candidate);
                    break;
                }
            }
            analyzer.references.items[index].symbol_id = @fromBackingInt(
                replacement orelse return error.MissingReplacementSymbol,
            );
        },
        .invalid_reference_scope => {
            const index = target_reference_index orelse return error.MissingTargetReference;
            analyzer.references.items[index].scope_id = @fromBackingInt(@intCast(analyzer.scopes.items.len + 1));
        },
        .invalid_binding_scope => {
            const symbol_id = analyzer.symbol_ids.items[raw] orelse return error.MissingTargetSymbol;
            analyzer.symbols.items[symbol_id].scope_id = .none;
        },
        .out_of_range_binding_scope => {
            const symbol_id = analyzer.symbol_ids.items[raw] orelse return error.MissingTargetSymbol;
            analyzer.symbols.items[symbol_id].scope_id = @fromBackingInt(@intCast(analyzer.scopes.items.len + 1));
        },
        .synthetic_binding => {
            const symbol_id = analyzer.symbol_ids.items[raw] orelse return error.MissingTargetSymbol;
            analyzer.symbols.items[symbol_id].synthetic_kind = .runtime_helper_import;
        },
    }

    const semantic = ModuleSemanticData{
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
    return canRetainGraphForSimpleDefineReferences(allocator, &parser.ast, &semantic, &defines);
}

test "simple define graph preflight rejects hostile syntax and graph evidence" {
    const local_source = "const flag = 1; function read() { return flag; }";
    const HostileCase = struct {
        source: []const u8,
        key: []const u8,
        value: []const u8,
        mutation: DefinePreflightMutation,
    };
    const cases = [_]HostileCase{
        .{ .source = local_source, .key = "flag", .value = "0", .mutation = .none },
        .{ .source = local_source, .key = "flag", .value = "globalThis.value", .mutation = .none },
        .{ .source = "const object = {}; function read() { return object.flag; }", .key = "object.flag", .value = "false", .mutation = .none },
        .{ .source = "const object = {}; function read() { return object?.flag; }", .key = "object.flag", .value = "false", .mutation = .none },
        .{ .source = "function read() { return flag; }", .key = "flag", .value = "false", .mutation = .none },
        .{ .source = "import { flag } from 'pkg'; function read() { return flag; }", .key = "flag", .value = "false", .mutation = .none },
        .{ .source = local_source, .key = "flag", .value = "false", .mutation = .truncated_symbol_id_map },
        .{ .source = "const flag = 1; function read() { return flag; }", .key = "flag", .value = "false", .mutation = .missing_symbol_id },
        .{ .source = local_source, .key = "flag", .value = "false", .mutation = .invalid_symbol_id },
        .{ .source = local_source, .key = "flag", .value = "false", .mutation = .import_binding },
        .{ .source = local_source, .key = "flag", .value = "false", .mutation = .duplicate_reference },
        .{ .source = local_source, .key = "flag", .value = "false", .mutation = .missing_reference },
        .{ .source = local_source, .key = "flag", .value = "false", .mutation = .mismatched_reference_symbol },
        .{ .source = local_source, .key = "flag", .value = "false", .mutation = .invalid_reference_scope },
        .{ .source = local_source, .key = "flag", .value = "false", .mutation = .invalid_binding_scope },
        .{ .source = local_source, .key = "flag", .value = "false", .mutation = .out_of_range_binding_scope },
        .{ .source = local_source, .key = "flag", .value = "false", .mutation = .synthetic_binding },
    };
    for (cases) |case| {
        try std.testing.expect(!try canRetainSimpleDefineForTest(
            case.source,
            case.key,
            case.value,
            case.mutation,
        ));
    }
    try std.testing.expect(!try canRetainSimpleDefineForTest(local_source, "missing", "false", .none));
    try std.testing.expect(try canRetainSimpleDefineForTest(local_source, "flag", "\"production\"", .none));
    try std.testing.expect(try canRetainSimpleDefineForTest(local_source, "flag", "true", .none));
    try std.testing.expect(try canRetainSimpleDefineForTest(local_source, "flag", "false", .none));
    try std.testing.expect(try canRetainSimpleDefineForTest(local_source, "flag", "null", .none));
    try std.testing.expect(try canRetainSimpleDefineForTest(local_source, "flag", "undefined", .none));
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
    const exact = try coverage.checkExactWithNamespaceMetadataAndDeclarationAnchors(
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
        // The source/output index boundary is meaningful only when this graph
        // retained source ScopeIds. A reanalyzed graph assigns scopes afresh.
        if (retained_graph) pre_transform_scope_count else null,
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
    var reanalyzed_unresolved_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer reanalyzed_unresolved_nodes.deinit(allocator);
    const exact_unresolved_nodes = if (retained_graph) unresolved_nodes else blk: {
        const semantic = if (module.semantic) |*value| value else return;
        collectParserUnresolvedNodes(
            allocator,
            &(module.ast orelse return),
            parser_node_count,
            semantic.symbol_ids,
            &semantic.unresolved_references,
            &reanalyzed_unresolved_nodes,
        ) catch |err| {
            std.debug.print("zntc: symbol-identity-prepass-error {s}: {s}\n", .{ module.path, @errorName(err) });
            return;
        };
        break :blk &reanalyzed_unresolved_nodes;
    };
    printPrepassExact(
        allocator,
        module,
        root,
        parser_node_count,
        transformer,
        exact_unresolved_nodes,
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
        const raw_name = ast.getText(node.span);
        if (!unresolved_references.contains(raw_name)) {
            if (std.mem.indexOfScalar(u8, raw_name, '\\') == null) continue;
            const decoded_name = try Scanner.decodeIdentifierEscapesAlloc(allocator, raw_name);
            if (!unresolved_references.contains(decoded_name)) continue;
        }
        try unresolved_nodes.put(allocator, @intCast(raw), {});
    }
}

/// transformer pre-pass — graph 단계에서 1회 실행.
/// 결과: `module.ast` 를 transformer 결과 AST 로 교체, `module.transform_cache` set,
/// final AST 기준 분석 데이터 refresh.
/// 실패 시 error diagnostic 을 남기고 모듈 파싱을 중단한다. stale semantic/binding
/// 데이터로 tree-shaker/linker 가 진행하는 silent bug 를 막기 위한 정책 (#1913).
fn captureWorkletFactoryLocalBindings(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
) ![]const WorkletFactoryLocalBinding {
    var binding_nodes: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer binding_nodes.deinit(allocator);
    for (ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or raw >= semantic.symbol_ids.len) continue;
        const raw_symbol_id = semantic.symbol_ids[raw] orelse continue;
        if (raw_symbol_id >= semantic.symbols.items.len) return error.InvalidWorkletFactorySymbolId;
        if (semantic.symbols.items[raw_symbol_id].synthetic_kind != .worklet_factory_local) continue;
        if (try binding_nodes.fetchPut(allocator, raw_symbol_id, @intCast(raw)) != null)
            return error.AmbiguousWorkletFactoryBinding;
    }

    var bindings: std.ArrayListUnmanaged(WorkletFactoryLocalBinding) = .empty;
    for (semantic.symbols.items, 0..) |symbol, symbol_index| {
        if (symbol.synthetic_kind != .worklet_factory_local) continue;
        if (symbol.output_name_hint.len == 0) return error.MissingWorkletFactoryOutputName;
        const raw_symbol_id: u32 = @intCast(symbol_index);
        const raw = binding_nodes.get(raw_symbol_id) orelse return error.MissingWorkletFactoryBinding;
        try bindings.append(allocator, .{
            .node_index = raw,
            .output_name_hint = symbol.output_name_hint,
        });
    }
    return bindings.toOwnedSlice(allocator);
}

fn isPostGraphOutputNameKind(kind: SemanticSyntheticKind) bool {
    return switch (kind) {
        .stage3_class_this_binding,
        .stage3_metadata_binding,
        .stage3_class_decorator_binding,
        .stage3_member_decorator_binding,
        .new_target_capture_binding,
        .this_capture_binding,
        .arguments_capture_binding,
        .object_super_home_binding,
        .tagged_template_function_binding,
        => true,
        else => false,
    };
}

fn isValidPostGraphOutputNameHint(kind: SemanticSyntheticKind, hint: []const u8) bool {
    return switch (kind) {
        .stage3_class_this_binding => std.mem.eql(u8, hint, "_classThis"),
        .stage3_metadata_binding => std.mem.eql(u8, hint, "_metadata"),
        .stage3_class_decorator_binding => std.mem.eql(u8, hint, "_classDecorators") or
            std.mem.eql(u8, hint, "_classDescriptor") or
            std.mem.eql(u8, hint, "_classExtraInitializers"),
        .stage3_member_decorator_binding => hint.len > 0,
        .new_target_capture_binding => std.mem.eql(u8, hint, "_newTarget"),
        .this_capture_binding => std.mem.eql(u8, hint, "_this"),
        .arguments_capture_binding => std.mem.eql(u8, hint, "_arguments"),
        .object_super_home_binding => std.mem.eql(u8, hint, "_obj"),
        .tagged_template_function_binding => std.mem.eql(u8, hint, "_templateObject"),
        else => false,
    };
}

fn isPostGraphOutputBindingKind(synthetic_kind: SemanticSyntheticKind, kind: SemanticSymbolKind) bool {
    return switch (synthetic_kind) {
        .new_target_capture_binding => switch (kind) {
            .variable_var, .variable_let, .variable_const, .parameter => true,
            else => false,
        },
        .stage3_class_this_binding,
        .stage3_metadata_binding,
        .stage3_class_decorator_binding,
        .stage3_member_decorator_binding,
        .this_capture_binding,
        .arguments_capture_binding,
        => switch (kind) {
            .variable_var, .variable_let, .variable_const => true,
            else => false,
        },
        .object_super_home_binding => kind == .parameter,
        .tagged_template_function_binding => kind == .function_decl,
        else => false,
    };
}

test "post-graph tagged-template cache requires its exact function binding metadata" {
    try std.testing.expect(isPostGraphOutputNameKind(.tagged_template_function_binding));
    try std.testing.expect(isValidPostGraphOutputNameHint(.tagged_template_function_binding, "_templateObject"));
    try std.testing.expect(!isValidPostGraphOutputNameHint(.tagged_template_function_binding, "_templateObject2"));
    try std.testing.expect(isPostGraphOutputBindingKind(.tagged_template_function_binding, .function_decl));
    try std.testing.expect(!isPostGraphOutputBindingKind(.tagged_template_function_binding, .variable_var));
}

/// Preserve exact producer binding nodes for names selected by
/// the linker after semantic reanalysis. Names are never recovered by text.
fn capturePostGraphOutputBindings(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
) ![]const PostGraphOutputBinding {
    var binding_nodes: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer binding_nodes.deinit(allocator);

    for (ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or raw >= semantic.symbol_ids.len) continue;
        const raw_symbol_id = semantic.symbol_ids[raw] orelse continue;
        if (raw_symbol_id >= semantic.symbols.items.len) return error.InvalidPostGraphOutputSymbolId;
        const symbol = semantic.symbols.items[raw_symbol_id];
        const kind = symbol.synthetic_kind orelse continue;
        if (!isPostGraphOutputNameKind(kind)) continue;
        if (!isValidPostGraphOutputNameHint(kind, symbol.output_name_hint) or symbol.scope_id.isNone() or
            !isPostGraphOutputBindingKind(kind, symbol.kind))
            return error.InvalidPostGraphOutputBindingMetadata;
        if (try binding_nodes.fetchPut(allocator, raw_symbol_id, @intCast(raw)) != null)
            return error.AmbiguousPostGraphOutputBinding;
    }

    var bindings: std.ArrayListUnmanaged(PostGraphOutputBinding) = .empty;
    for (semantic.symbols.items, 0..) |symbol, raw_symbol_id| {
        const kind = symbol.synthetic_kind orelse continue;
        if (!isPostGraphOutputNameKind(kind)) continue;
        if (!isValidPostGraphOutputNameHint(kind, symbol.output_name_hint) or symbol.scope_id.isNone() or
            !isPostGraphOutputBindingKind(kind, symbol.kind))
            return error.InvalidPostGraphOutputBindingMetadata;
        const raw = binding_nodes.get(@intCast(raw_symbol_id)) orelse return error.MissingPostGraphOutputBinding;
        try bindings.append(allocator, .{
            .node_index = raw,
            .output_name_hint = symbol.output_name_hint,
            .synthetic_kind = kind,
            .binding_kind = symbol.kind,
        });
    }
    return bindings.toOwnedSlice(allocator);
}

/// Preserve generated runtime-import identity metadata through post-transform
/// semantic reanalysis. The transformer map supplies exact import-local
/// NodeIndices; no spelling or source-span recovery is involved.
fn captureRuntimeHelperImportOutputBindings(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    import_bindings: *const std.AutoHashMapUnmanaged(u32, u32),
) ![]const RuntimeHelperImportOutputBinding {
    var bindings: std.ArrayListUnmanaged(RuntimeHelperImportOutputBinding) = .empty;
    var it = import_bindings.iterator();
    while (it.next()) |entry| {
        const raw_symbol_id = entry.key_ptr.*;
        if (raw_symbol_id >= semantic.symbols.items.len) return error.InvalidRuntimeHelperImportSymbolId;
        const symbol = semantic.symbols.items[raw_symbol_id];
        if (symbol.synthetic_kind != .runtime_helper_import) continue;
        if (symbol.kind != .import_binding or symbol.scope_id.isNone() or
            symbol.output_name_hint.len == 0 or
            !std.mem.eql(u8, symbol.synthetic_name, symbol.output_name_hint))
            return error.InvalidRuntimeHelperImportOutputMetadata;

        const raw_node = entry.value_ptr.*;
        if (raw_node >= ast.nodes.items.len) return error.InvalidRuntimeHelperImportNode;
        const node = ast.nodes.items[raw_node];
        if (node.tag != .identifier_reference and node.tag != .import_default_specifier)
            return error.InvalidRuntimeHelperImportNode;
        if (!std.mem.eql(u8, ast.getText(node.data.string_ref), symbol.synthetic_name))
            return error.RuntimeHelperImportNameMismatch;
        try bindings.append(allocator, .{
            .node_index = raw_node,
            .output_name_hint = symbol.output_name_hint,
        });
    }
    return bindings.toOwnedSlice(allocator);
}

/// 비-ESM 출력은 TLA 를 항상 미지원으로 둔다(#4598). TLA 가 없는 모듈에는 그 비트가 출력에
/// 영향을 주지 않으므로, 그래프 유지 판정(`hasAny`)과 변환에서 빼고 보아 이전과 같게 둔다.
/// TLA 유무는 파싱 때(변환 전) 기록한 `self_uses_top_level_await` 다.
fn moduleUnsupported(unsupported: TransformOptions.compat.UnsupportedFeatures, module: *const Module) TransformOptions.compat.UnsupportedFeatures {
    var result = unsupported;
    if (!module.self_uses_top_level_await) result.top_level_await = false;
    return result;
}

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
    const has_nested_worklet_function_scopes = if (module.semantic) |*semantic|
        hasNestedWorkletFunctionScope(ast_ptr, semantic)
    else
        true;
    const safe_builtin_worklet = self.worklet_transform and self.plugins.len == 0 and
        !self.styled_components and !self.emotion and
        !moduleUnsupported(self.transform_options_base.unsupported, module).hasAny() and !ast_ptr.has_jsx and !ast_ptr.has_decorator and
        !has_nested_worklet_function_scopes and
        isBuiltinWorkletPluginSet(merged_plugins);

    const parser_node_count: u32 = @intCast(ast_ptr.nodes.items.len);

    var opts = self.transform_options_base;
    opts.unsupported = moduleUnsupported(opts.unsupported, module);
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

    const object_spread_scan =
        if (opts.unsupported.object_spread) hasReachableObjectSpread(ast_ptr) else @as(?bool, false);
    const exponentiation_scan = if (opts.unsupported.exponentiation)
        hasReachableExponentiation(ast_ptr)
    else
        @as(?bool, false);
    const downlevel_static_public_class_field_scan =
        if (opts.unsupported.class or opts.unsupported.class_field)
            hasReachableStaticPublicClassField(ast_ptr)
        else
            @as(?bool, false);
    const has_dropped_labeled_statement = hasDroppedLabeledStatement(ast_ptr, opts.drop_labels);
    var allow_es5_async_method_super_get = false;
    var allow_es5_async_method_super_set = false;
    var retained_simple_console_drops = false;
    var can_keep_semantic_graph = object_spread_scan != null and exponentiation_scan != null and
        downlevel_static_public_class_field_scan != null and
        canKeepPrepassSemanticGraph(
            self,
            module,
            opts,
            merged_plugins,
            &allow_es5_async_method_super_get,
            &allow_es5_async_method_super_set,
            &retained_simple_console_drops,
        );
    var retained_console_object_references: []ast_mod.NodeIndex = &.{};
    if (can_keep_semantic_graph and opts.drop_console and hasDroppedConsoleStatement(ast_ptr)) {
        if (collectRetainedConsoleObjectReferences(arena_alloc, ast_ptr)) |references| {
            retained_console_object_references = references;
        } else {
            // The graph gate should make this collection infallible apart from
            // allocation failure. Keep the analyzer fallback as the recovery
            // path if its preflight evidence cannot be reproduced here.
            can_keep_semantic_graph = false;
        }
    }
    // Class lowering removes source class nodes. Cache the derived-class
    // evidence before transforming so its helper imports can be admitted only
    // for modules that passed the full retained-graph preflight.
    const allow_derived_class_helpers = can_keep_semantic_graph and opts.unsupported.class and
        hasReachableDerivedClass(ast_ptr);
    const allow_stage3_decorator_helpers = can_keep_semantic_graph and
        canRetainStage3DecoratorGraph(ast_ptr, opts);
    const allow_legacy_decorator_helpers = can_keep_semantic_graph and
        canRetainLegacyDecoratorGraph(module, ast_ptr, opts);
    const allow_async_helper = can_keep_semantic_graph and opts.unsupported.async_await;
    const lowered_simple_static_class_field_global = can_keep_semantic_graph and
        (downlevel_static_public_class_field_scan orelse
            (opts.unsupported.class or opts.unsupported.class_field));
    const flow_match_generated_globals = flowMatchGeneratedGlobals(ast_ptr);
    // If reachability allocation fails, reanalysis is already forced above.
    // Still record any generated Object reference conservatively in that path.
    const has_lowered_object_spread = object_spread_scan orelse opts.unsupported.object_spread;
    const lowered_object_spread_global = can_keep_semantic_graph and has_lowered_object_spread;
    const has_lowered_exponentiation = exponentiation_scan orelse false;
    const lowered_exponentiation_global = can_keep_semantic_graph and has_lowered_exponentiation;
    const debug_symbol_coverage = symbol_coverage_env.enabled();
    const pre_transform_scope_count = if (module.semantic) |*sem| sem.scopes.len else 0;

    var transformer = Transformer.init(arena_alloc, ast_ptr, opts) catch return;
    transformer.record_explicit_global_references = shouldRecordPrepassExplicitGlobals(
        can_keep_semantic_graph,
        ast_ptr,
        opts,
        flow_match_generated_globals.has_match,
        has_lowered_object_spread,
        has_lowered_exponentiation,
        safe_builtin_worklet,
        downlevel_static_public_class_field_scan orelse (opts.unsupported.class or opts.unsupported.class_field),
    );

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
        transformer.namespace_member_owners = &sem.namespace_member_owners;
        transformer.namespace_declaration_owners = &sem.namespace_declaration_owners;
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
    if (debug_symbol_coverage and ast_ptr.transformed_root == null and parser_node_count > 0) {
        if (module.semantic) |*sem| {
            const coverage = @import("../../transformer/symbol_coverage.zig");
            const source_root: ast_mod.NodeIndex = @fromBackingInt(@intCast(parser_node_count - 1));
            const source_scope_owner_audit = coverage.checkExactWithCompleteSourceScopeOwners(
                arena_alloc,
                ast_ptr,
                source_root,
                parser_node_count,
                sem.symbol_ids,
                sem.symbols.items,
                sem.scopes,
                sem.scope_maps,
                &sem.scope_owner_map,
                sem.references,
                &.{},
                &sem.helper_scope_map,
                &unresolved_nodes,
                &transformer.explicit_global_reference_nodes,
                &transformer.reference_origin_map,
            ) catch return;
            coverage.printSourceScopeOwnerAudit(module.path, source_scope_owner_audit);
        }
    }

    // #4598: 청크에 위임한 경우, **변환 전** AST 에서 TLA 유무를 확인해 전용 필드에 남긴다.
    // 변환 뒤에 도는 analyzer 로는 알 수 없고(그 변환이 await 를 없앤다), 전역
    // `uses_top_level_await` 를 넓히면 다른 경로가 함께 바뀐다(4차 회귀 원인).
    if (opts.tla_chunk_wrapped and opts.unsupported.top_level_await) {
        const es2022_tla_mod = @import("../../transformer/es2022_tla.zig");
        if (ast_ptr.nodes.items.len > 0) {
            const root_idx: @import("../../parser/ast.zig").NodeIndex = @fromBackingInt(@intCast(ast_ptr.nodes.items.len - 1));
            module.tla_delegated_to_chunk = es2022_tla_mod.hasTopLevelAwait(ast_ptr, root_idx) catch false;
        }
    }

    const root = transformer.transform() catch return;
    for (retained_console_object_references) |reference| {
        transformer.removeSemanticReference(reference) catch return;
    }
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
    // Removing a labeled statement or console call can shift statement indices
    // and detach declarations or source scopes. Reindex the surviving graph,
    // then retain it only when the exact gate proves live bindings, references,
    // owners, counts, and statement coordinates still agree. Any uncertain
    // case uses the analyzer below.
    if (can_keep_semantic_graph and
        (hasDroppedLabeledStatement(ast_ptr, opts.drop_labels) or retained_simple_console_drops))
    {
        if (module.semantic) |*semantic| {
            const updated_references = reindexMinifiedSemanticReferences(
                arena_alloc,
                transformer.ast,
                root,
                semantic.references,
            ) catch null;
            if (updated_references) |references| {
                semantic.references = references;
                transformer.references = references;
                can_keep_semantic_graph = canRetainMinifiedSemanticGraph(
                    arena_alloc,
                    transformer.ast,
                    root,
                    semantic.symbols.items,
                    semantic.scopes,
                    semantic.references,
                    transformer.symbol_ids.items,
                    &semantic.unresolved_references,
                    &semantic.scope_owner_map,
                    null,
                );
            } else {
                can_keep_semantic_graph = false;
            }
        } else {
            can_keep_semantic_graph = false;
        }
    }
    // #4598: `lowerProgram` 이 만든 async IIFE statement 를 module 로 넘긴다 —
    // emitter 가 `__esm` factory 안에서 그 문장만 `return <expr>;` 로 방출한다.
    if (transformer.tla_iife_stmt) |ix| {
        module.tla_iife_stmt = @backingInt(ix);
        module.tla_promise_reference = null;
    }
    // #4210: 다운레벨 못한 ES2025 inline modifier 가 출력에 보존됨 → loud 진단
    // (transform-driven — 실제 fold bail 반영). transpile path 와 동일 메시지.
    if (transformer.used_unsupported_modifier) {
        self.addDiag(.regex_modifier_unsupported, .warning, module.path, Span.EMPTY, .parse, TransformOptions.regex_modifier_unsupported_msg, null);
    }
    if (transformer.used_unsupported_exponentiation) {
        self.addDiag(.exponentiation_dynamic_scope, .warning, module.path, Span.EMPTY, .parse, TransformOptions.exponentiation_dynamic_scope_msg, null);
    }
    if (transformer.used_unsupported_arrow_dynamic_scope) {
        self.addDiag(.arrow_dynamic_scope, .warning, module.path, Span.EMPTY, .parse, TransformOptions.arrow_dynamic_scope_msg, null);
    }
    if (transformer.used_unsupported_arrow_dynamic_eval) {
        self.addDiag(.arrow_dynamic_eval, .warning, module.path, Span.EMPTY, .parse, TransformOptions.arrow_dynamic_eval_msg, null);
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
    const pre_minify_statement_lists: ?[]MinifiedStatementList = if (can_keep_semantic_graph and
        self.transform_options_base.minify_syntax)
        snapshotMinifiedStatementLists(arena_alloc, transformer.ast) catch null
    else
        null;
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
        ctx.preserve_inferred_names = !self.minify_identifiers or self.transform_options_base.keep_names;
        if (ctx.hasSemantic()) {
            if (arena_alloc.alloc(u32, ctx.symbols.len)) |buf| {
                @memset(buf, 0);
                prepass_ref_deltas = buf;
                ctx.ref_deltas = buf;
            } else |_| {}
        }
        minify_mod.minify(transformer.ast, ctx, arena_alloc, root);
    }

    // A successful transform graph is not automatically valid after syntax
    // minification: folding can delete identifier edges or move an identifier
    // to another AST slot. Retain the existing SymbolIds only when the final
    // reachable AST, declarations, references, scopes, and counts still agree.
    // Otherwise use the normal graph metadata resync and semantic analyzer.
    if (can_keep_semantic_graph and self.transform_options_base.minify_syntax) {
        if (pre_minify_statement_lists) |before| {
            const after = snapshotMinifiedStatementLists(arena_alloc, transformer.ast) catch null;
            if (after) |current| {
                can_keep_semantic_graph = minifiedStatementListsEqual(before, current);
            } else {
                can_keep_semantic_graph = false;
            }
        } else {
            can_keep_semantic_graph = false;
        }
        if (can_keep_semantic_graph) {
            if (module.semantic) |*semantic| {
                const updated_references = reindexMinifiedSemanticReferences(
                    arena_alloc,
                    transformer.ast,
                    root,
                    semantic.references,
                ) catch null;
                if (updated_references) |references| {
                    semantic.references = references;
                    can_keep_semantic_graph = canRetainMinifiedSemanticGraph(
                        arena_alloc,
                        transformer.ast,
                        root,
                        semantic.symbols.items,
                        semantic.scopes,
                        semantic.references,
                        transformer.symbol_ids.items,
                        &semantic.unresolved_references,
                        &semantic.scope_owner_map,
                        null,
                    );
                } else {
                    can_keep_semantic_graph = false;
                }
            } else {
                can_keep_semantic_graph = false;
            }
        }
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
    const owned_worklet_factory_local_bindings = if (module.semantic) |*semantic|
        captureWorkletFactoryLocalBindings(arena_alloc, transformer.ast, semantic) catch return
    else
        &[_]WorkletFactoryLocalBinding{};
    const owned_post_graph_output_bindings = if (module.semantic) |*semantic|
        capturePostGraphOutputBindings(arena_alloc, transformer.ast, semantic) catch return
    else
        &[_]PostGraphOutputBinding{};
    const owned_runtime_helper_import_output_bindings = if (module.semantic) |*semantic|
        captureRuntimeHelperImportOutputBindings(
            arena_alloc,
            transformer.ast,
            semantic,
            &transformer.runtime_helper_import_bindings,
        ) catch return
    else
        &[_]RuntimeHelperImportOutputBinding{};
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
        .worklet_factory_local_bindings = owned_worklet_factory_local_bindings,
        .post_graph_output_bindings = owned_post_graph_output_bindings,
        .runtime_helper_import_output_bindings = owned_runtime_helper_import_output_bindings,
        .ref_deltas = prepass_ref_deltas,
    };

    if (shouldRefreshRetainedModuleTopLevelAwait(
        can_keep_semantic_graph,
        retained_simple_console_drops,
        has_dropped_labeled_statement,
        module.self_uses_top_level_await,
    )) {
        // Finalize resets the transitive bit from this module-local bit before
        // propagating TLA through the updated import graph.
        if (!refreshRetainedModuleTopLevelAwait(arena_alloc, transformer.ast, module)) {
            can_keep_semantic_graph = false;
        }
    }

    // Type erasure, Flow match lowering, TypeScript enums, supported JSX,
    // Stage 3 decorators, bounded named-class cases, and audited
    // iterator/destructuring/spread subsets preserve the edited semantic
    // graph. JSX, decorators, and syntax lowering may add synthetic helper
    // imports, so refresh module graph metadata without replacing that graph.
    if (can_keep_semantic_graph and runtimeHelpersSafeForRetainedGraph(
        transformer.runtime_helpers,
        allow_derived_class_helpers,
        allow_stage3_decorator_helpers,
        allow_legacy_decorator_helpers,
        allow_async_helper,
        allow_es5_async_method_super_get,
        allow_es5_async_method_super_set,
    )) {
        // Generated built-ins are not source references, so the transform
        // editor cannot add them to unresolved_references. If recording them
        // runs out of memory, use the normal analyzer refresh below.
        addFlowMatchGeneratedGlobals(arena_alloc, &module.semantic.?, flow_match_generated_globals) catch {};
        if (lowered_object_spread_global)
            addGeneratedGlobal(arena_alloc, &module.semantic.?, "Object") catch {};
        if (lowered_exponentiation_global)
            addGeneratedGlobal(arena_alloc, &module.semantic.?, "Math") catch {};
        if (lowered_simple_static_class_field_global)
            addGeneratedGlobal(arena_alloc, &module.semantic.?, "Object") catch {};
        const worklet_global_reference = safe_builtin_worklet and hasExplicitGlobalReferenceNamed(
            ast_ptr,
            &transformer.explicit_global_reference_nodes,
            "global",
        );
        if (worklet_global_reference)
            addGeneratedGlobal(arena_alloc, &module.semantic.?, "global") catch {};
        const generated_globals_recorded =
            (!flow_match_generated_globals.array or module.semantic.?.unresolved_references.contains("Array")) and
            (!flow_match_generated_globals.object or module.semantic.?.unresolved_references.contains("Object")) and
            (!lowered_object_spread_global or module.semantic.?.unresolved_references.contains("Object")) and
            (!lowered_exponentiation_global or module.semantic.?.unresolved_references.contains("Math")) and
            (!lowered_simple_static_class_field_global or module.semantic.?.unresolved_references.contains("Object")) and
            (!worklet_global_reference or module.semantic.?.unresolved_references.contains("global"));
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
        if (self.transform_options_base.minify_syntax) {
            if (module.semantic) |semantic| {
                // Syntax minification can change statement-use information
                // even when every surviving identifier edge still has the
                // same SymbolId. Rebuild the tree-shaker buckets from the
                // retained graph instead of leaving them empty after the
                // graph-metadata refresh.
                module.prebuilt_stmt_info = stmt_info_mod.buildFromSemantic(
                    arena_alloc,
                    &module.ast.?,
                    semantic.symbols.items,
                    semantic.scopes,
                    semantic.references,
                    &semantic.unresolved_references,
                    false,
                    module.memberAugmentGate(self.transform_options_base.minify_syntax),
                ) catch {
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
            }
        }
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

/// Graph-level wrapper/runtime bindings have no AST declaration node to anchor
/// their fresh SymbolIds. The module owns exactly one producer slot for the
/// singleton kinds below, so their identity is the typed synthetic kind as
/// long as each semantic snapshot contains exactly one matching row.
fn isModuleOwnedSingletonGraphSynthetic(kind: SemanticSyntheticKind) bool {
    return switch (kind) {
        .cjs_exports,
        .cjs_require,
        .esm_init,
        .cjs_wrapper_exports_parameter,
        .cjs_wrapper_module_parameter,
        .cjs_runtime_factory,
        => true,
        else => false,
    };
}

fn isGraphOwnedSyntheticRename(symbol: SemanticSymbol) bool {
    const kind = symbol.synthetic_kind orelse return false;
    // Graph-wide runtime helpers have stable producer slots on Module and
    // carry linker-chosen spellings. Let their exact slot remappers own them.
    if (kind == .bundler_runtime_helper) {
        if (std.mem.eql(u8, symbol.synthetic_name, "__esm") or
            std.mem.eql(u8, symbol.synthetic_name, "__toBinary")) return false;
        inline for (runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS) |helper| {
            if (std.mem.eql(u8, symbol.synthetic_name, runtime_helper_names.esmInteropRuntimeHelperBaseName(helper))) return false;
        }
    }
    return switch (kind) {
        .cjs_exports,
        .cjs_require,
        .esm_init,
        .cjs_wrapper_exports_parameter,
        .cjs_wrapper_module_parameter,
        .cjs_runtime_factory,
        .esm_interop_runtime_internal_local,
        .bundler_runtime_helper,
        .require_shim_local,
        => true,
        else => false,
    };
}

fn sameGraphOwnedSyntheticIdentity(a: SemanticSymbol, b: SemanticSymbol) bool {
    if (!isGraphOwnedSyntheticRename(a) or !isGraphOwnedSyntheticRename(b)) return false;
    const kind = a.synthetic_kind orelse return false;
    if (kind != b.synthetic_kind or a.kind != b.kind) return false;
    if (isModuleOwnedSingletonGraphSynthetic(kind)) return true;
    return a.scope_id == b.scope_id and std.mem.eql(u8, a.synthetic_name, b.synthetic_name);
}

fn remapGraphOwnedSyntheticRenames(
    allocator: std.mem.Allocator,
    module_index: bundler_symbol.ModuleIndex,
    old_symbols: []const SemanticSymbol,
    new_symbols: []const SemanticSymbol,
    old_renames: []const ?[]const u8,
    rebuilt: *bundler_symbol.RenameTable,
) !void {
    for (old_symbols, 0..) |old_symbol, old_idx| {
        if (!isGraphOwnedSyntheticRename(old_symbol) or old_idx >= old_renames.len) continue;
        const rename = old_renames[old_idx] orelse continue;

        var old_matches: usize = 0;
        for (old_symbols) |candidate| {
            if (sameGraphOwnedSyntheticIdentity(old_symbol, candidate)) old_matches += 1;
        }
        if (old_matches != 1) continue;

        var new_match: ?usize = null;
        var new_matches: usize = 0;
        for (new_symbols, 0..) |candidate, new_idx| {
            if (!sameGraphOwnedSyntheticIdentity(old_symbol, candidate)) continue;
            new_match = new_idx;
            new_matches += 1;
        }
        if (new_matches != 1) continue;

        const new_id = bundler_symbol.SymbolID.make(module_index, new_match.?);
        // A source-node anchor already mapped this exact row. Keep that mapping
        // if its evidence disagrees; never replace it with a name-based guess.
        if (rebuilt.get(new_id)) |existing| {
            if (std.mem.eql(u8, existing, rename)) continue;
            continue;
        }
        try rebuilt.put(allocator, new_id, rename);
    }
}

fn graphOwnedSyntheticRenameTestSymbol(
    synthetic_kind: SemanticSyntheticKind,
    kind: SemanticSymbolKind,
    scope_raw: u32,
    name: []const u8,
) SemanticSymbol {
    return .{
        .name = Span.EMPTY,
        .kind = kind,
        .scope_id = @fromBackingInt(@intCast(scope_raw)),
        .declaration_span = Span.EMPTY,
        .synthetic_kind = synthetic_kind,
        .synthetic_name = name,
    };
}

const CjsRuntimeInternalRenameSlot = struct {
    symbol_id: SemanticSymbolId,
    symbol_kind: SemanticSymbolKind,
};

fn cjsRuntimeInternalRenameSlots(ids: CjsRuntimeInternalSymbolIds) [4]CjsRuntimeInternalRenameSlot {
    return .{
        .{ .symbol_id = ids.callback_parameter, .symbol_kind = .parameter },
        .{ .symbol_id = ids.module_parameter, .symbol_kind = .parameter },
        .{ .symbol_id = ids.catch_parameter, .symbol_kind = .catch_binding },
        .{ .symbol_id = ids.require_function, .symbol_kind = .function_decl },
    };
}

fn validCjsRuntimeInternalRenameSlots(
    slots: [4]CjsRuntimeInternalRenameSlot,
    symbols: []const SemanticSymbol,
) bool {
    for (slots, 0..) |slot, slot_index| {
        if (slot.symbol_id.isNone()) return false;
        const raw: usize = @backingInt(slot.symbol_id);
        if (raw >= symbols.len) return false;
        const symbol = symbols[raw];
        if (symbol.synthetic_kind != .cjs_runtime_internal_local or symbol.kind != slot.symbol_kind) return false;
        for (slots[0..slot_index]) |prior| {
            if (prior.symbol_id == slot.symbol_id) return false;
        }
    }
    return true;
}

/// These four runtime locals have stable producer slots on Module. Reanalysis
/// assigns fresh semantic indexes and may change names/scopes, so carry their
/// linker names by the old/new slot IDs instead of a structural name match.
fn remapCjsRuntimeInternalRenames(
    allocator: std.mem.Allocator,
    module_index: bundler_symbol.ModuleIndex,
    old_symbols: []const SemanticSymbol,
    new_symbols: []const SemanticSymbol,
    old_renames: []const ?[]const u8,
    old_ids: ?CjsRuntimeInternalSymbolIds,
    new_ids: ?CjsRuntimeInternalSymbolIds,
    rebuilt: *bundler_symbol.RenameTable,
) !void {
    const old_slots = cjsRuntimeInternalRenameSlots(old_ids orelse return);
    const new_slots = cjsRuntimeInternalRenameSlots(new_ids orelse return);
    if (!validCjsRuntimeInternalRenameSlots(old_slots, old_symbols) or
        !validCjsRuntimeInternalRenameSlots(new_slots, new_symbols)) return;
    for (old_slots) |slot| {
        if (@backingInt(slot.symbol_id) >= old_renames.len) return;
    }

    for (old_slots, new_slots) |old_slot, new_slot| {
        const old_index: usize = @backingInt(old_slot.symbol_id);
        const new_index: usize = @backingInt(new_slot.symbol_id);
        const rename = old_renames[old_index] orelse continue;
        const new_id = bundler_symbol.SymbolID.make(module_index, new_index);
        // Preserve an AST-anchor mapping if it already reached this row.
        if (rebuilt.get(new_id) != null) continue;
        try rebuilt.put(allocator, new_id, rename);
    }
}

test "CJS runtime internal renames follow exact producer slots across reanalysis" {
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(7));
    const old_ids: CjsRuntimeInternalSymbolIds = .{
        .callback_parameter = @fromBackingInt(@as(u32, 0)),
        .module_parameter = @fromBackingInt(@as(u32, 1)),
        .catch_parameter = @fromBackingInt(@as(u32, 2)),
        .require_function = @fromBackingInt(@as(u32, 3)),
    };
    const new_ids: CjsRuntimeInternalSymbolIds = .{
        .callback_parameter = @fromBackingInt(@as(u32, 3)),
        .module_parameter = @fromBackingInt(@as(u32, 1)),
        .catch_parameter = @fromBackingInt(@as(u32, 4)),
        .require_function = @fromBackingInt(@as(u32, 2)),
    };
    const old_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .parameter, 1, "old_callback"),
        graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .parameter, 1, "old_module"),
        graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .catch_binding, 2, "old_catch"),
        graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .function_decl, 2, "old_require"),
    };
    const new_symbols = [_]SemanticSymbol{
        .{
            .name = Span.EMPTY,
            .kind = .variable_let,
            .scope_id = @fromBackingInt(@as(u32, 0)),
            .declaration_span = Span.EMPTY,
        },
        graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .parameter, 8, "new_module"),
        graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .function_decl, 9, "new_require"),
        graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .parameter, 7, "new_callback"),
        graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .catch_binding, 9, "new_catch"),
    };
    const old_renames: [4]?[]const u8 = .{ "callback_final", "module_final", "catch_final", "require_final" };
    var rebuilt: bundler_symbol.RenameTable = .{};
    defer rebuilt.deinit(std.testing.allocator);

    try remapGraphOwnedSyntheticRenames(
        std.testing.allocator,
        module_index,
        &old_symbols,
        &new_symbols,
        &old_renames,
        &rebuilt,
    );
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());
    try remapCjsRuntimeInternalRenames(
        std.testing.allocator,
        module_index,
        &old_symbols,
        &new_symbols,
        &old_renames,
        old_ids,
        new_ids,
        &rebuilt,
    );

    try std.testing.expectEqual(@as(u32, 4), rebuilt.count());
    try std.testing.expectEqualStrings("callback_final", rebuilt.get(bundler_symbol.SymbolID.make(module_index, 3)).?);
    try std.testing.expectEqualStrings("module_final", rebuilt.get(bundler_symbol.SymbolID.make(module_index, 1)).?);
    try std.testing.expectEqualStrings("catch_final", rebuilt.get(bundler_symbol.SymbolID.make(module_index, 4)).?);
    try std.testing.expectEqualStrings("require_final", rebuilt.get(bundler_symbol.SymbolID.make(module_index, 2)).?);
}

test "CJS runtime internal rename remapping fails closed on invalid slot evidence" {
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(7));
    const valid_ids: CjsRuntimeInternalSymbolIds = .{
        .callback_parameter = @fromBackingInt(@as(u32, 0)),
        .module_parameter = @fromBackingInt(@as(u32, 1)),
        .catch_parameter = @fromBackingInt(@as(u32, 2)),
        .require_function = @fromBackingInt(@as(u32, 3)),
    };
    const valid_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .parameter, 1, "cb"),
        graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .parameter, 1, "mod"),
        graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .catch_binding, 2, "err"),
        graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .function_decl, 2, "require"),
    };
    const renames: [4]?[]const u8 = .{ "cb_final", "mod_final", "err_final", "require_final" };
    var rebuilt: bundler_symbol.RenameTable = .{};
    defer rebuilt.deinit(std.testing.allocator);

    try remapCjsRuntimeInternalRenames(std.testing.allocator, module_index, &valid_symbols, &valid_symbols, &renames, null, valid_ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());
    try remapCjsRuntimeInternalRenames(std.testing.allocator, module_index, &valid_symbols, &valid_symbols, &renames, valid_ids, null, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    const short_renames: [3]?[]const u8 = .{ "cb_final", "mod_final", "err_final" };
    try remapCjsRuntimeInternalRenames(std.testing.allocator, module_index, &valid_symbols, &valid_symbols, &short_renames, valid_ids, valid_ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var duplicate_old = valid_ids;
    duplicate_old.module_parameter = duplicate_old.callback_parameter;
    try remapCjsRuntimeInternalRenames(std.testing.allocator, module_index, &valid_symbols, &valid_symbols, &renames, duplicate_old, valid_ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var duplicate_new = valid_ids;
    duplicate_new.module_parameter = duplicate_new.callback_parameter;
    try remapCjsRuntimeInternalRenames(std.testing.allocator, module_index, &valid_symbols, &valid_symbols, &renames, valid_ids, duplicate_new, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var out_of_bounds = valid_ids;
    out_of_bounds.catch_parameter = @fromBackingInt(@as(u32, 4));
    try remapCjsRuntimeInternalRenames(std.testing.allocator, module_index, &valid_symbols, &valid_symbols, &renames, valid_ids, out_of_bounds, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var old_out_of_bounds = valid_ids;
    old_out_of_bounds.callback_parameter = @fromBackingInt(@as(u32, 4));
    try remapCjsRuntimeInternalRenames(std.testing.allocator, module_index, &valid_symbols, &valid_symbols, &renames, old_out_of_bounds, valid_ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var wrong_old_kind = valid_symbols;
    wrong_old_kind[0] = graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .function_decl, 1, "cb");
    try remapCjsRuntimeInternalRenames(std.testing.allocator, module_index, &wrong_old_kind, &valid_symbols, &renames, valid_ids, valid_ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var wrong_old_synthetic = valid_symbols;
    wrong_old_synthetic[0] = graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .parameter, 1, "cb");
    try remapCjsRuntimeInternalRenames(std.testing.allocator, module_index, &wrong_old_synthetic, &valid_symbols, &renames, valid_ids, valid_ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var wrong_new_kind = valid_symbols;
    wrong_new_kind[3] = graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .parameter, 1, "require");
    try remapCjsRuntimeInternalRenames(std.testing.allocator, module_index, &valid_symbols, &wrong_new_kind, &renames, valid_ids, valid_ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var wrong_new_synthetic = valid_symbols;
    wrong_new_synthetic[3] = graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .function_decl, 1, "require");
    try remapCjsRuntimeInternalRenames(std.testing.allocator, module_index, &valid_symbols, &wrong_new_synthetic, &renames, valid_ids, valid_ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    const callback_id = bundler_symbol.SymbolID.make(module_index, 0);
    try rebuilt.put(std.testing.allocator, callback_id, "node_anchor_final");
    try remapCjsRuntimeInternalRenames(std.testing.allocator, module_index, &valid_symbols, &valid_symbols, &renames, valid_ids, valid_ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 4), rebuilt.count());
    try std.testing.expectEqualStrings("node_anchor_final", rebuilt.get(callback_id).?);
}

test "CJS runtime internal renames do not use the generic name and scope fallback" {
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(7));
    const old_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .parameter, 1, "stable_callback"),
    };
    const new_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_internal_local, .parameter, 1, "stable_callback"),
    };
    const old_renames: [1]?[]const u8 = .{"callback_final"};
    var rebuilt: bundler_symbol.RenameTable = .{};
    defer rebuilt.deinit(std.testing.allocator);

    try remapGraphOwnedSyntheticRenames(
        std.testing.allocator,
        module_index,
        &old_symbols,
        &new_symbols,
        &old_renames,
        &rebuilt,
    );

    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());
}

const EsmRuntimeInternalRenameSlot = struct {
    symbol_id: SemanticSymbolId,
    symbol_kind: SemanticSymbolKind,
    synthetic_name: []const u8,
};

fn esmRuntimeInternalRenameSlots(ids: EsmRuntimeInternalSymbolIds) [5]EsmRuntimeInternalRenameSlot {
    const names: runtime_helper_names.EsmRuntimeInternalNames = .{};
    return .{
        .{ .symbol_id = ids.factory_parameter, .symbol_kind = .parameter, .synthetic_name = names.factory_parameter },
        .{ .symbol_id = ids.result_parameter, .symbol_kind = .parameter, .synthetic_name = names.result_parameter },
        .{ .symbol_id = ids.catch_parameter, .symbol_kind = .catch_binding, .synthetic_name = names.catch_parameter },
        .{ .symbol_id = ids.init_function, .symbol_kind = .function_decl, .synthetic_name = names.init_function },
        .{ .symbol_id = ids.factory_local, .symbol_kind = .variable_var, .synthetic_name = names.factory_local },
    };
}

fn validEsmRuntimeInternalRenameSlots(
    slots: [5]EsmRuntimeInternalRenameSlot,
    symbols: []const SemanticSymbol,
) bool {
    for (slots, 0..) |slot, slot_index| {
        if (slot.symbol_id.isNone()) return false;
        const raw: usize = @backingInt(slot.symbol_id);
        if (raw >= symbols.len) return false;
        const symbol = symbols[raw];
        if (symbol.synthetic_kind != .esm_runtime_internal_local or
            symbol.kind != slot.symbol_kind or
            !std.mem.eql(u8, symbol.synthetic_name, slot.synthetic_name)) return false;
        for (slots[0..slot_index]) |prior| {
            if (prior.symbol_id == slot.symbol_id) return false;
        }
    }
    return true;
}

/// ESM runtime locals have stable producer slots on Module. Reanalysis creates
/// fresh semantic indexes and can move their scopes, so preserve linker names
/// through those slots instead of matching the synthetic spelling and scope.
fn remapEsmRuntimeInternalRenames(
    allocator: std.mem.Allocator,
    module_index: bundler_symbol.ModuleIndex,
    old_symbols: []const SemanticSymbol,
    new_symbols: []const SemanticSymbol,
    old_renames: []const ?[]const u8,
    old_ids: ?EsmRuntimeInternalSymbolIds,
    new_ids: ?EsmRuntimeInternalSymbolIds,
    rebuilt: *bundler_symbol.RenameTable,
) !void {
    const old_slots = esmRuntimeInternalRenameSlots(old_ids orelse return);
    const new_slots = esmRuntimeInternalRenameSlots(new_ids orelse return);
    if (!validEsmRuntimeInternalRenameSlots(old_slots, old_symbols) or
        !validEsmRuntimeInternalRenameSlots(new_slots, new_symbols)) return;
    for (old_slots) |slot| {
        if (@backingInt(slot.symbol_id) >= old_renames.len) return;
    }

    for (old_slots, new_slots) |old_slot, new_slot| {
        const old_index: usize = @backingInt(old_slot.symbol_id);
        const new_index: usize = @backingInt(new_slot.symbol_id);
        const rename = old_renames[old_index] orelse continue;
        const new_id = bundler_symbol.SymbolID.make(module_index, new_index);
        // Keep an exact NodeIndex mapping when it already supplied evidence.
        if (rebuilt.get(new_id) != null) continue;
        try rebuilt.put(allocator, new_id, rename);
    }
}

fn validEsmRuntimeFactorySymbol(symbol_id: SemanticSymbolId, symbols: []const SemanticSymbol) bool {
    if (symbol_id.isNone()) return false;
    const raw: usize = @backingInt(symbol_id);
    if (raw >= symbols.len) return false;
    const symbol = symbols[raw];
    return symbol.synthetic_kind == .bundler_runtime_helper and
        symbol.kind == .variable_var and
        std.mem.eql(u8, symbol.synthetic_name, "__esm");
}

fn esmInteropRuntimeHelperSlots(ids: EsmInteropRuntimeHelperSymbolIds) [runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS.len]SemanticSymbolId {
    var slots: [runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS.len]SemanticSymbolId = undefined;
    inline for (runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS, 0..) |helper, index| {
        slots[index] = @field(ids, @tagName(helper));
    }
    return slots;
}

fn esmInteropRuntimeHelperIdsFromSlots(
    slots: [runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS.len]SemanticSymbolId,
) EsmInteropRuntimeHelperSymbolIds {
    var ids: EsmInteropRuntimeHelperSymbolIds = undefined;
    inline for (runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS, 0..) |helper, index| {
        @field(ids, @tagName(helper)) = slots[index];
    }
    return ids;
}

fn validEsmInteropRuntimeHelperSlots(
    slots: [runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS.len]SemanticSymbolId,
    symbols: []const SemanticSymbol,
) bool {
    inline for (runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS, 0..) |helper, index| {
        const id = slots[index];
        if (id.isNone()) return false;
        const raw: usize = @backingInt(id);
        if (raw >= symbols.len) return false;
        const symbol = symbols[raw];
        if (symbol.synthetic_kind != .bundler_runtime_helper or
            symbol.kind != .variable_var or
            !std.mem.eql(u8, symbol.synthetic_name, runtime_helper_names.esmInteropRuntimeHelperBaseName(helper)))
        {
            return false;
        }
    }
    for (slots, 0..) |id, index| {
        for (slots[0..index]) |previous| {
            if (id == previous) return false;
        }
    }
    return true;
}

fn hasEsmInteropRuntimeHelperRows(symbols: []const SemanticSymbol) bool {
    for (symbols) |symbol| {
        if (symbol.synthetic_kind != .bundler_runtime_helper) continue;
        inline for (runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS) |helper| {
            if (std.mem.eql(u8, symbol.synthetic_name, runtime_helper_names.esmInteropRuntimeHelperBaseName(helper))) return true;
        }
    }
    return false;
}

/// The graph-wide ESM factory name is collision-selected by its producer ID.
/// Carry it to the refreshed row by Module's exact slot, not by its spelling.
fn remapEsmRuntimeFactoryRename(
    allocator: std.mem.Allocator,
    module_index: bundler_symbol.ModuleIndex,
    old_symbols: []const SemanticSymbol,
    new_symbols: []const SemanticSymbol,
    old_renames: []const ?[]const u8,
    old_id: ?SemanticSymbolId,
    new_id: ?SemanticSymbolId,
    rebuilt: *bundler_symbol.RenameTable,
) !void {
    const old_symbol_id = old_id orelse return;
    const new_symbol_id = new_id orelse return;
    if (!validEsmRuntimeFactorySymbol(old_symbol_id, old_symbols) or
        !validEsmRuntimeFactorySymbol(new_symbol_id, new_symbols)) return;
    const old_index: usize = @backingInt(old_symbol_id);
    if (old_index >= old_renames.len) return;
    const rename = old_renames[old_index] orelse return;
    const new_id_key = bundler_symbol.SymbolID.make(module_index, @backingInt(new_symbol_id));
    // Keep a NodeIndex mapping if it already supplied more specific evidence.
    if (rebuilt.get(new_id_key) != null) return;
    try rebuilt.put(allocator, new_id_key, rename);
}

fn remapEsmInteropRuntimeHelperRenames(
    allocator: std.mem.Allocator,
    module_index: bundler_symbol.ModuleIndex,
    old_symbols: []const SemanticSymbol,
    new_symbols: []const SemanticSymbol,
    old_renames: []const ?[]const u8,
    old_ids: ?EsmInteropRuntimeHelperSymbolIds,
    new_ids: ?EsmInteropRuntimeHelperSymbolIds,
    rebuilt: *bundler_symbol.RenameTable,
) !void {
    const old_slots = esmInteropRuntimeHelperSlots(old_ids orelse return);
    const new_slots = esmInteropRuntimeHelperSlots(new_ids orelse return);
    if (!validEsmInteropRuntimeHelperSlots(old_slots, old_symbols) or
        !validEsmInteropRuntimeHelperSlots(new_slots, new_symbols)) return;

    for (old_slots, 0..) |old_id, index| {
        const old_index: usize = @backingInt(old_id);
        if (old_index >= old_renames.len) continue;
        const rename = old_renames[old_index] orelse continue;
        const new_id_key = bundler_symbol.SymbolID.make(module_index, @backingInt(new_slots[index]));
        // Preserve a stronger exact-node mapping when the new AST provides one.
        if (rebuilt.get(new_id_key) != null) continue;
        try rebuilt.put(allocator, new_id_key, rename);
    }
}

fn validToBinaryRuntimeHelperSymbol(symbol_id: SemanticSymbolId, symbols: []const SemanticSymbol) bool {
    if (symbol_id.isNone()) return false;
    const raw: usize = @backingInt(symbol_id);
    if (raw >= symbols.len) return false;
    const symbol = symbols[raw];
    return symbol.synthetic_kind == .bundler_runtime_helper and
        symbol.kind == .variable_var and
        std.mem.eql(u8, symbol.synthetic_name, "__toBinary");
}

const RuntimeHelperReanalysisTestFixture = struct {
    ast: ast_mod.Ast,
    semantic: ModuleSemanticData,
};

fn runtimeHelperReanalysisTestFixture(
    allocator: std.mem.Allocator,
    source: []const u8,
) !RuntimeHelperReanalysisTestFixture {
    var scanner = try Scanner.init(allocator, source);
    scanner.is_module = true;
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.is_module = true;
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_stmt_info = true;
    try analyzer.analyze();

    return .{
        .ast = parser.ast,
        .semantic = .{
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
        },
    };
}

fn toBinaryReanalysisTestSymbol() SemanticSymbol {
    var symbol = graphOwnedSyntheticRenameTestSymbol(
        .bundler_runtime_helper,
        .variable_var,
        0,
        "__toBinary",
    );
    symbol.scope_id = .none;
    symbol.decl_flags = SemanticSymbolKind.variable_var.declFlags();
    symbol.output_name_hint = "__toBinary$producer";
    symbol.reference_count = 3;
    symbol.write_count = 1;
    return symbol;
}

const EsmRuntimeReanalysisTestRows = struct {
    factory_id: SemanticSymbolId,
    internal_ids: EsmRuntimeInternalSymbolIds,
    factory_symbol: SemanticSymbol,
    internal_symbols: [5]SemanticSymbol,
};

fn esmRuntimeReanalysisTestFactorySymbol() SemanticSymbol {
    var symbol = graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 0, "__esm");
    symbol.scope_id = .none;
    symbol.decl_flags = SemanticSymbolKind.variable_var.declFlags();
    symbol.output_name_hint = "__esm$producer";
    symbol.reference_count = 2;
    symbol.write_count = 1;
    return symbol;
}

fn esmRuntimeReanalysisTestInternalSymbols() [5]SemanticSymbol {
    const names: runtime_helper_names.EsmRuntimeInternalNames = .{};
    const kinds = [_]SemanticSymbolKind{
        .parameter,
        .parameter,
        .catch_binding,
        .function_decl,
        .variable_var,
    };
    const synthetic_names = [_][]const u8{
        names.factory_parameter,
        names.result_parameter,
        names.catch_parameter,
        names.init_function,
        names.factory_local,
    };
    var symbols: [5]SemanticSymbol = undefined;
    for (kinds, 0..) |kind, index| {
        var symbol = graphOwnedSyntheticRenameTestSymbol(
            .esm_runtime_internal_local,
            kind,
            0,
            synthetic_names[index],
        );
        symbol.scope_id = .none;
        symbol.decl_flags = kind.declFlags();
        symbol.output_name_hint = "esm-internal$producer";
        symbol.reference_count = @intCast(index + 1);
        symbol.write_count = 1;
        symbols[index] = symbol;
    }
    return symbols;
}

fn appendEsmRuntimeReanalysisTestRows(
    allocator: std.mem.Allocator,
    symbols: *std.ArrayList(SemanticSymbol),
) !EsmRuntimeReanalysisTestRows {
    const factory_symbol = esmRuntimeReanalysisTestFactorySymbol();
    const factory_id: SemanticSymbolId = @fromBackingInt(@intCast(symbols.items.len));
    try symbols.append(allocator, factory_symbol);

    const internal_symbols = esmRuntimeReanalysisTestInternalSymbols();
    var internal_ids: [5]SemanticSymbolId = undefined;
    for (internal_symbols, 0..) |symbol, index| {
        internal_ids[index] = @fromBackingInt(@intCast(symbols.items.len));
        try symbols.append(allocator, symbol);
    }
    return .{
        .factory_id = factory_id,
        .internal_ids = .{
            .factory_parameter = internal_ids[0],
            .result_parameter = internal_ids[1],
            .catch_parameter = internal_ids[2],
            .init_function = internal_ids[3],
            .factory_local = internal_ids[4],
        },
        .factory_symbol = factory_symbol,
        .internal_symbols = internal_symbols,
    };
}

fn appendEsmInteropRuntimeHelperReanalysisTestRows(
    allocator: std.mem.Allocator,
    symbols: *std.ArrayList(SemanticSymbol),
) !EsmInteropRuntimeHelperSymbolIds {
    var ids: EsmInteropRuntimeHelperSymbolIds = undefined;
    inline for (runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS) |helper| {
        const symbol = graphOwnedSyntheticRenameTestSymbol(
            .bundler_runtime_helper,
            .variable_var,
            0,
            runtime_helper_names.esmInteropRuntimeHelperBaseName(helper),
        );
        @field(ids, @tagName(helper)) = @fromBackingInt(@intCast(symbols.items.len));
        try symbols.append(allocator, symbol);
    }
    return ids;
}

fn esmRuntimeReanalysisTestIdsAt(first_internal_index: usize) EsmRuntimeInternalSymbolIds {
    return .{
        .factory_parameter = @fromBackingInt(@intCast(first_internal_index)),
        .result_parameter = @fromBackingInt(@intCast(first_internal_index + 1)),
        .catch_parameter = @fromBackingInt(@intCast(first_internal_index + 2)),
        .init_function = @fromBackingInt(@intCast(first_internal_index + 3)),
        .factory_local = @fromBackingInt(@intCast(first_internal_index + 4)),
    };
}

test "toBinary runtime helper producer row survives hostile semantic reanalysis" {
    const HostileSource = struct {
        source: []const u8,
        has_source_binding: bool,
    };
    const hostile_sources = [_]HostileSource{
        .{ .source = "let __toBinary;", .has_source_binding = true },
        .{ .source = "const __toBinary = 1;", .has_source_binding = true },
        .{ .source = "function __toBinary() { return 1; }", .has_source_binding = true },
        .{ .source = "class __toBinary {}", .has_source_binding = true },
        .{ .source = "function nested(__toBinary) { return __toBinary; }", .has_source_binding = true },
        .{ .source = "function nested() { var __toBinary; return __toBinary; }", .has_source_binding = true },
        .{ .source = "const { __toBinary } = { __toBinary: 1 };", .has_source_binding = true },
        .{ .source = "const [__toBinary] = [1];", .has_source_binding = true },
        .{ .source = "try { throw 1; } catch (__toBinary) { void __toBinary; }", .has_source_binding = true },
        .{ .source = "const holder = { __toBinary: 1 }; holder.__toBinary;", .has_source_binding = false },
    };

    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();

    var old_semantic = (try runtimeHelperReanalysisTestFixture(allocator, "const previous = 1;")).semantic;
    try old_semantic.symbols.append(allocator, toBinaryReanalysisTestSymbol());
    const old_id: SemanticSymbolId = @fromBackingInt(@intCast(old_semantic.symbols.items.len - 1));
    const old_symbol = old_semantic.symbols.items[@backingInt(old_id)];
    var old_renames = try allocator.alloc(?[]const u8, old_semantic.symbols.items.len);
    @memset(old_renames, null);
    old_renames[@backingInt(old_id)] = "__toBinary$producer";

    var module = Module.init(@fromBackingInt(@intCast(11)), "to-binary-shadow.js");
    module.parse_arena = &test_arena;

    for (hostile_sources) |hostile| {
        const fresh_fixture = try runtimeHelperReanalysisTestFixture(allocator, hostile.source);
        const fresh_len = fresh_fixture.semantic.symbols.items.len;
        var saw_source_binding = false;
        for (fresh_fixture.semantic.symbols.items) |symbol| {
            if (symbol.synthetic_kind != null) continue;
            if (std.mem.eql(u8, fresh_fixture.ast.getText(symbol.name), "__toBinary")) {
                saw_source_binding = true;
                break;
            }
        }
        try std.testing.expectEqual(hostile.has_source_binding, saw_source_binding);

        module.semantic = fresh_fixture.semantic;
        module.to_binary_runtime_symbol = old_id;
        try carryToBinaryRuntimeHelperSymbolAfterReanalysis(&module, old_semantic, allocator);

        const expected_new_id: SemanticSymbolId = @fromBackingInt(@intCast(fresh_len));
        try std.testing.expectEqual(expected_new_id, module.to_binary_runtime_symbol.?);
        const new_symbols = module.semantic.?.symbols.items;
        try std.testing.expectEqual(fresh_len + 1, new_symbols.len);
        try std.testing.expectEqualDeep(old_symbol, new_symbols[@backingInt(expected_new_id)]);

        var rebuilt: bundler_symbol.RenameTable = .{};
        defer rebuilt.deinit(std.testing.allocator);
        try remapToBinaryRuntimeHelperRename(
            std.testing.allocator,
            module.index,
            old_semantic.symbols.items,
            new_symbols,
            old_renames,
            old_id,
            module.to_binary_runtime_symbol,
            &rebuilt,
        );
        const rename_key = bundler_symbol.SymbolID.make(module.index, @backingInt(expected_new_id));
        try std.testing.expectEqual(@as(u32, 1), rebuilt.count());
        try std.testing.expectEqualStrings("__toBinary$producer", rebuilt.get(rename_key).?);
    }
}

test "toBinary runtime helper reanalysis carry fails closed on invalid producer evidence" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();
    const fresh_fixture = try runtimeHelperReanalysisTestFixture(allocator, "const live = 1;");
    const fresh_len = fresh_fixture.semantic.symbols.items.len;
    var module = Module.init(@fromBackingInt(@intCast(0)), "to-binary-invalid.js");
    module.semantic = fresh_fixture.semantic;

    try carryToBinaryRuntimeHelperSymbolAfterReanalysis(&module, null, allocator);
    try std.testing.expectEqual(fresh_len, module.semantic.?.symbols.items.len);
    module.to_binary_runtime_symbol = null;
    const previous = try runtimeHelperReanalysisTestFixture(allocator, "const previous = 1;");
    try carryToBinaryRuntimeHelperSymbolAfterReanalysis(&module, previous.semantic, allocator);
    try std.testing.expectEqual(fresh_len, module.semantic.?.symbols.items.len);

    const invalid_rows = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 0, "__esm"),
        graphOwnedSyntheticRenameTestSymbol(.runtime_helper_preamble, .variable_var, 0, "__toBinary"),
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_let, 0, "__toBinary"),
    };
    for (invalid_rows) |invalid_row| {
        var previous_with_invalid_row = try runtimeHelperReanalysisTestFixture(allocator, "const prior = 1;");
        try previous_with_invalid_row.semantic.symbols.append(allocator, invalid_row);
        module.to_binary_runtime_symbol = @fromBackingInt(@intCast(previous_with_invalid_row.semantic.symbols.items.len - 1));
        try std.testing.expectError(
            error.InvalidToBinaryRuntimeHelperProducerSymbol,
            carryToBinaryRuntimeHelperSymbolAfterReanalysis(&module, previous_with_invalid_row.semantic, allocator),
        );
        try std.testing.expectEqual(fresh_len, module.semantic.?.symbols.items.len);
    }

    var previous_with_valid_row = try runtimeHelperReanalysisTestFixture(allocator, "const prior = 1;");
    try previous_with_valid_row.semantic.symbols.append(allocator, toBinaryReanalysisTestSymbol());
    module.to_binary_runtime_symbol = @fromBackingInt(@intCast(previous_with_valid_row.semantic.symbols.items.len));
    try std.testing.expectError(
        error.InvalidToBinaryRuntimeHelperProducerSymbol,
        carryToBinaryRuntimeHelperSymbolAfterReanalysis(&module, previous_with_valid_row.semantic, allocator),
    );

    module.semantic = null;
    module.to_binary_runtime_symbol = @fromBackingInt(@intCast(previous_with_valid_row.semantic.symbols.items.len - 1));
    try std.testing.expectError(
        error.MissingSemantic,
        carryToBinaryRuntimeHelperSymbolAfterReanalysis(&module, previous_with_valid_row.semantic, allocator),
    );
}

test "toBinary runtime helper reanalysis preserves its rename through the production resync" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();
    const old_source = "const previous = 1;";
    const new_source = "let __toBinary = 1; const later = 2;";
    var old_fixture = try runtimeHelperReanalysisTestFixture(allocator, old_source);
    const fresh_fixture = try runtimeHelperReanalysisTestFixture(allocator, new_source);
    try old_fixture.semantic.symbols.append(allocator, toBinaryReanalysisTestSymbol());
    const old_id: SemanticSymbolId = @fromBackingInt(@intCast(old_fixture.semantic.symbols.items.len - 1));
    const old_symbol = old_fixture.semantic.symbols.items[@backingInt(old_id)];

    var module = Module.init(@fromBackingInt(@intCast(4)), "to-binary-resync.js");
    module.source = new_source;
    module.ast = fresh_fixture.ast;
    module.parse_arena = &test_arena;
    module.semantic = old_fixture.semantic;
    module.to_binary_runtime_symbol = old_id;

    var initial_renames: bundler_symbol.RenameTable = .{};
    defer initial_renames.deinit(std.testing.allocator);
    try initial_renames.put(
        std.testing.allocator,
        bundler_symbol.SymbolID.make(module.index, @backingInt(old_id)),
        "__toBinary$producer",
    );

    const test_context = .{
        .allocator = std.testing.allocator,
        .defines = &[_]@import("../../parser/scan_results.zig").DefineEntry{},
        .flow = false,
        .ignore_annotations = false,
        .minify_identifiers = false,
        .pure = &[_][]const u8{},
        .wrapper_symbols_registered = false,
        .wrap_kinds_finalized = true,
        .transform_options_base = .{ .minify_syntax = false },
    };
    try resyncAfterAstMutation(&test_context, &module, allocator, &initial_renames);

    const new_id = module.to_binary_runtime_symbol.?;
    try std.testing.expectEqual(fresh_fixture.semantic.symbols.items.len, @as(usize, @backingInt(new_id)));
    try std.testing.expectEqualDeep(old_symbol, module.semantic.?.symbols.items[@backingInt(new_id)]);
    const pending_key = bundler_symbol.SymbolID.make(module.index, @backingInt(new_id));
    try std.testing.expectEqual(@as(u32, 1), module.pending_renames.count());
    try std.testing.expectEqualStrings("__toBinary$producer", module.pending_renames.get(pending_key).?);
}

test "ESM interop helper producer group survives hostile semantic reanalysis" {
    const hostile_sources = [_][]const u8{
        "let __create;",
        "const __getProtoOf = 1;",
        "function __defProp() {}",
        "class __getOwnPropNames {}",
        "var __getOwnPropDesc;",
        "let __hasOwn = null;",
        "function __copyProps() { return 1; }",
        "const __toESM = {};",
        "let __export;",
        "class __toCommonJS {}",
    };

    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();

    var old_semantic = (try runtimeHelperReanalysisTestFixture(allocator, "const previous = 1;")).semantic;
    const old_ids = try appendEsmInteropRuntimeHelperReanalysisTestRows(allocator, &old_semantic.symbols);
    const old_start: usize = old_semantic.symbols.items.len - runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS.len;
    const old_rows = try allocator.dupe(SemanticSymbol, old_semantic.symbols.items[old_start..]);
    var module = Module.init(@fromBackingInt(@intCast(27)), "esm-interop-shadow.js");
    module.parse_arena = &test_arena;

    for (hostile_sources) |source| {
        const fresh_fixture = try runtimeHelperReanalysisTestFixture(allocator, source);
        const fresh_len = fresh_fixture.semantic.symbols.items.len;
        module.semantic = fresh_fixture.semantic;
        module.esm_interop_runtime_helper_symbols = old_ids;
        try carryEsmInteropRuntimeHelperSymbolsAfterReanalysis(&module, old_semantic, allocator);

        const new_symbols = module.semantic.?.symbols.items;
        try std.testing.expectEqual(fresh_len + runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS.len, new_symbols.len);
        const new_ids = module.esm_interop_runtime_helper_symbols orelse return error.TestUnexpectedResult;
        inline for (runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS, 0..) |helper, index| {
            const expected_id: SemanticSymbolId = @fromBackingInt(@intCast(fresh_len + index));
            try std.testing.expectEqual(expected_id, @field(new_ids, @tagName(helper)));
            try std.testing.expectEqualDeep(old_rows[index], new_symbols[fresh_len + index]);
        }
    }
}

test "ESM interop helper reanalysis fails closed on missing or malformed producer rows" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();
    const fresh_fixture = try runtimeHelperReanalysisTestFixture(allocator, "const current = 1;");
    var previous = try runtimeHelperReanalysisTestFixture(allocator, "const previous = 1;");
    const ids = try appendEsmInteropRuntimeHelperReanalysisTestRows(allocator, &previous.semantic.symbols);
    var module = Module.init(@fromBackingInt(@intCast(28)), "esm-interop-invalid.js");
    module.semantic = fresh_fixture.semantic;
    module.esm_interop_runtime_helper_symbols = ids;

    try carryEsmInteropRuntimeHelperSymbolsAfterReanalysis(&module, null, allocator);
    module.esm_interop_runtime_helper_symbols = null;
    try std.testing.expectError(
        error.MissingEsmInteropRuntimeProducerSymbols,
        carryEsmInteropRuntimeHelperSymbolsAfterReanalysis(&module, previous.semantic, allocator),
    );

    module.esm_interop_runtime_helper_symbols = ids;
    const original = previous.semantic.symbols.items[@backingInt(ids.create)];
    previous.semantic.symbols.items[@backingInt(ids.create)].synthetic_name = "__getProtoOf";
    try std.testing.expectError(
        error.InvalidEsmInteropRuntimeProducerSymbols,
        carryEsmInteropRuntimeHelperSymbolsAfterReanalysis(&module, previous.semantic, allocator),
    );
    previous.semantic.symbols.items[@backingInt(ids.create)] = original;

    const missing_semantic = module.semantic;
    module.semantic = null;
    try std.testing.expectError(
        error.MissingSemantic,
        carryEsmInteropRuntimeHelperSymbolsAfterReanalysis(&module, previous.semantic, allocator),
    );
    module.semantic = missing_semantic;
}

test "ESM interop helper rename handoff uses exact producer slots with duplicate rows" {
    const allocator = std.testing.allocator;
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@as(u32, 31));
    var old_symbols: std.ArrayList(SemanticSymbol) = .empty;
    defer old_symbols.deinit(allocator);
    var new_symbols: std.ArrayList(SemanticSymbol) = .empty;
    defer new_symbols.deinit(allocator);
    const old_ids = try appendEsmInteropRuntimeHelperReanalysisTestRows(allocator, &old_symbols);
    try new_symbols.append(allocator, graphOwnedSyntheticRenameTestSymbol(.require_shim_local, .import_binding, 0, "decoy0"));
    try new_symbols.append(allocator, graphOwnedSyntheticRenameTestSymbol(.require_shim_local, .import_binding, 0, "decoy1"));
    const new_ids = try appendEsmInteropRuntimeHelperReanalysisTestRows(allocator, &new_symbols);
    inline for (runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS) |helper| {
        const name = runtime_helper_names.esmInteropRuntimeHelperBaseName(helper);
        try old_symbols.append(allocator, graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 0, name));
        try new_symbols.append(allocator, graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 0, name));
    }

    const old_renames = try allocator.alloc(?[]const u8, old_symbols.items.len);
    defer allocator.free(old_renames);
    @memset(old_renames, null);
    inline for (runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS) |helper| {
        old_renames[@backingInt(@field(old_ids, @tagName(helper)))] = "exact-producer-name";
    }
    var rebuilt: bundler_symbol.RenameTable = .{};
    defer rebuilt.deinit(allocator);

    try remapGraphOwnedSyntheticRenames(allocator, module_index, old_symbols.items, new_symbols.items, old_renames, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());
    try remapEsmInteropRuntimeHelperRenames(
        allocator,
        module_index,
        old_symbols.items,
        new_symbols.items,
        old_renames,
        old_ids,
        new_ids,
        &rebuilt,
    );
    try std.testing.expectEqual(@as(u32, runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS.len), rebuilt.count());
    inline for (runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS) |helper| {
        const new_id = @field(new_ids, @tagName(helper));
        const key = bundler_symbol.SymbolID.make(module_index, @backingInt(new_id));
        const mapped_name = rebuilt.get(key) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("exact-producer-name", mapped_name);
    }
}

test "ESM runtime helper producer group survives hostile semantic reanalysis" {
    const HostileSource = struct {
        source: []const u8,
        binding_name: []const u8,
        has_source_binding: bool,
    };
    const hostile_sources = [_]HostileSource{
        .{ .source = "let __esm;", .binding_name = "__esm", .has_source_binding = true },
        .{ .source = "const __esm = 1;", .binding_name = "__esm", .has_source_binding = true },
        .{ .source = "function __esm() { return 1; }", .binding_name = "__esm", .has_source_binding = true },
        .{ .source = "class __esm {}", .binding_name = "__esm", .has_source_binding = true },
        .{ .source = "function nested(fn) { return fn; }", .binding_name = "fn", .has_source_binding = true },
        .{ .source = "function nested() { let res; return res; }", .binding_name = "res", .has_source_binding = true },
        .{ .source = "try { throw 1; } catch (e) { void e; }", .binding_name = "e", .has_source_binding = true },
        .{ .source = "function __init() {}", .binding_name = "__init", .has_source_binding = true },
        .{ .source = "const [f] = [1];", .binding_name = "f", .has_source_binding = true },
        .{ .source = "const holder = { __esm: 1 }; holder.__esm;", .binding_name = "__esm", .has_source_binding = false },
    };
    const rename_names = [_][]const u8{
        "__esm$factory",
        "fn$factory_parameter",
        "res$result_parameter",
        "e$catch_parameter",
        "__init$init_function",
        "f$factory_local",
    };

    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();

    var old_semantic = (try runtimeHelperReanalysisTestFixture(allocator, "const previous = 1;")).semantic;
    const old_rows = try appendEsmRuntimeReanalysisTestRows(allocator, &old_semantic.symbols);
    var old_renames = try allocator.alloc(?[]const u8, old_semantic.symbols.items.len);
    @memset(old_renames, null);
    old_renames[@backingInt(old_rows.factory_id)] = rename_names[0];
    for (esmRuntimeInternalRenameSlots(old_rows.internal_ids), 0..) |slot, index| {
        old_renames[@backingInt(slot.symbol_id)] = rename_names[index + 1];
    }

    var module = Module.init(@fromBackingInt(@intCast(19)), "esm-runtime-shadow.js");
    module.parse_arena = &test_arena;
    for (hostile_sources) |hostile| {
        const fresh_fixture = try runtimeHelperReanalysisTestFixture(allocator, hostile.source);
        const fresh_len = fresh_fixture.semantic.symbols.items.len;
        var saw_source_binding = false;
        for (fresh_fixture.semantic.symbols.items) |symbol| {
            if (symbol.synthetic_kind != null) continue;
            if (std.mem.eql(u8, fresh_fixture.ast.getText(symbol.name), hostile.binding_name)) {
                saw_source_binding = true;
                break;
            }
        }
        try std.testing.expectEqual(hostile.has_source_binding, saw_source_binding);

        module.semantic = fresh_fixture.semantic;
        module.esm_runtime_factory_symbol = old_rows.factory_id;
        module.esm_runtime_internal_symbols = old_rows.internal_ids;
        try carryEsmRuntimeHelperSymbolsAfterReanalysis(&module, old_semantic, allocator);

        const expected_factory_id: SemanticSymbolId = @fromBackingInt(@intCast(fresh_len));
        const expected_internal_ids = esmRuntimeReanalysisTestIdsAt(fresh_len + 1);
        try std.testing.expectEqual(expected_factory_id, module.esm_runtime_factory_symbol.?);
        try std.testing.expectEqualDeep(expected_internal_ids, module.esm_runtime_internal_symbols.?);
        const new_symbols = module.semantic.?.symbols.items;
        try std.testing.expectEqual(fresh_len + 6, new_symbols.len);
        try std.testing.expectEqualDeep(old_rows.factory_symbol, new_symbols[@backingInt(expected_factory_id)]);
        const new_internal_rows = esmRuntimeReanalysisTestInternalSymbols();
        for (new_internal_rows, 0..) |expected_symbol, index| {
            try std.testing.expectEqualDeep(expected_symbol, new_symbols[fresh_len + index + 1]);
        }

        var rebuilt: bundler_symbol.RenameTable = .{};
        defer rebuilt.deinit(std.testing.allocator);
        try remapEsmRuntimeFactoryRename(
            std.testing.allocator,
            module.index,
            old_semantic.symbols.items,
            new_symbols,
            old_renames,
            old_rows.factory_id,
            module.esm_runtime_factory_symbol,
            &rebuilt,
        );
        try remapEsmRuntimeInternalRenames(
            std.testing.allocator,
            module.index,
            old_semantic.symbols.items,
            new_symbols,
            old_renames,
            old_rows.internal_ids,
            module.esm_runtime_internal_symbols,
            &rebuilt,
        );
        try std.testing.expectEqual(@as(u32, 6), rebuilt.count());
        const factory_key = bundler_symbol.SymbolID.make(module.index, @backingInt(expected_factory_id));
        try std.testing.expectEqualStrings(rename_names[0], rebuilt.get(factory_key).?);
        for (esmRuntimeInternalRenameSlots(expected_internal_ids), 0..) |slot, index| {
            const key = bundler_symbol.SymbolID.make(module.index, @backingInt(slot.symbol_id));
            try std.testing.expectEqualStrings(rename_names[index + 1], rebuilt.get(key).?);
        }
    }
}

test "ESM interop helper IDs survive production resync and rename handoff" {
    const allocator = std.testing.allocator;
    const new_source = "let __create; const __getProtoOf = 1; function __defProp() {} class __getOwnPropNames {} var __getOwnPropDesc; let __hasOwn; function __copyProps() {} const __toESM = {}; let __export; class __toCommonJS {}";
    var test_arena = std.heap.ArenaAllocator.init(allocator);
    defer test_arena.deinit();
    const arena_allocator = test_arena.allocator();
    var old_semantic = (try runtimeHelperReanalysisTestFixture(arena_allocator, "const previous = 1;")).semantic;
    const old_ids = try appendEsmInteropRuntimeHelperReanalysisTestRows(arena_allocator, &old_semantic.symbols);
    const fresh_fixture = try runtimeHelperReanalysisTestFixture(arena_allocator, new_source);
    const fresh_len = fresh_fixture.semantic.symbols.items.len;
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@as(u32, 29));

    var initial_renames: bundler_symbol.RenameTable = .{};
    defer initial_renames.deinit(allocator);
    inline for (runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS) |helper| {
        const old_id = @field(old_ids, @tagName(helper));
        const rename = try std.fmt.allocPrint(arena_allocator, "{s}$producer", .{runtime_helper_names.esmInteropRuntimeHelperBaseName(helper)});
        try initial_renames.put(allocator, bundler_symbol.SymbolID.make(module_index, @backingInt(old_id)), rename);
    }

    var module = Module.init(module_index, "esm-interop-resync.js");
    module.source = new_source;
    module.ast = fresh_fixture.ast;
    module.parse_arena = &test_arena;
    module.semantic = old_semantic;
    module.esm_interop_runtime_helper_symbols = old_ids;

    const test_context = .{
        .allocator = allocator,
        .defines = &[_]@import("../../parser/scan_results.zig").DefineEntry{},
        .flow = false,
        .ignore_annotations = false,
        .minify_identifiers = false,
        .pure = &[_][]const u8{},
        .wrapper_symbols_registered = false,
        .wrap_kinds_finalized = true,
        .transform_options_base = .{ .minify_syntax = false },
    };
    try resyncAfterAstMutation(&test_context, &module, arena_allocator, &initial_renames);

    const new_ids = module.esm_interop_runtime_helper_symbols orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(fresh_len + runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS.len, module.semantic.?.symbols.items.len);
    try std.testing.expectEqual(@as(u32, 10), module.pending_renames.count());
    inline for (runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS, 0..) |helper, index| {
        const expected_id: SemanticSymbolId = @fromBackingInt(@intCast(fresh_len + index));
        try std.testing.expectEqual(expected_id, @field(new_ids, @tagName(helper)));
        const pending_key = bundler_symbol.SymbolID.make(module.index, @backingInt(expected_id));
        const expected_name = try std.fmt.allocPrint(arena_allocator, "{s}$producer", .{runtime_helper_names.esmInteropRuntimeHelperBaseName(helper)});
        const pending_name = module.pending_renames.get(pending_key) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected_name, pending_name);
    }
}

test "ESM runtime helper reanalysis carry fails closed on invalid producer evidence" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();
    const fresh_fixture = try runtimeHelperReanalysisTestFixture(allocator, "const live = 1;");
    const fresh_len = fresh_fixture.semantic.symbols.items.len;
    var module = Module.init(@fromBackingInt(@intCast(0)), "esm-runtime-invalid.js");
    module.semantic = fresh_fixture.semantic;

    try carryEsmRuntimeHelperSymbolsAfterReanalysis(&module, null, allocator);
    try std.testing.expectEqual(fresh_len, module.semantic.?.symbols.items.len);
    try carryEsmRuntimeHelperSymbolsAfterReanalysis(&module, fresh_fixture.semantic, allocator);
    try std.testing.expectEqual(fresh_len, module.semantic.?.symbols.items.len);

    var valid_previous = try runtimeHelperReanalysisTestFixture(allocator, "const previous = 1;");
    const valid_rows = try appendEsmRuntimeReanalysisTestRows(allocator, &valid_previous.semantic.symbols);
    module.esm_runtime_factory_symbol = valid_rows.factory_id;
    module.esm_runtime_internal_symbols = null;
    try std.testing.expectError(
        error.MissingEsmRuntimeInternalProducerSymbols,
        carryEsmRuntimeHelperSymbolsAfterReanalysis(&module, valid_previous.semantic, allocator),
    );

    const invalid_factory_rows = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.runtime_helper_preamble, .variable_var, 0, "__esm"),
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_let, 0, "__esm"),
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 0, "__toBinary"),
    };
    for (invalid_factory_rows) |invalid_factory| {
        var previous = try runtimeHelperReanalysisTestFixture(allocator, "const previous = 1;");
        const invalid_factory_id: SemanticSymbolId = @fromBackingInt(@intCast(previous.semantic.symbols.items.len));
        try previous.semantic.symbols.append(allocator, invalid_factory);
        module.esm_runtime_factory_symbol = invalid_factory_id;
        module.esm_runtime_internal_symbols = null;
        try std.testing.expectError(
            error.InvalidEsmRuntimeFactoryProducerSymbol,
            carryEsmRuntimeHelperSymbolsAfterReanalysis(&module, previous.semantic, allocator),
        );
        try std.testing.expectEqual(fresh_len, module.semantic.?.symbols.items.len);
    }

    module.esm_runtime_factory_symbol = @fromBackingInt(@intCast(valid_previous.semantic.symbols.items.len));
    try std.testing.expectError(
        error.InvalidEsmRuntimeFactoryProducerSymbol,
        carryEsmRuntimeHelperSymbolsAfterReanalysis(&module, valid_previous.semantic, allocator),
    );

    var previous_with_bad_internal = try runtimeHelperReanalysisTestFixture(allocator, "const previous = 1;");
    const bad_internal_rows = try appendEsmRuntimeReanalysisTestRows(allocator, &previous_with_bad_internal.semantic.symbols);
    previous_with_bad_internal.semantic.symbols.items[@backingInt(bad_internal_rows.internal_ids.factory_parameter)] =
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .parameter, 0, "fn");
    module.esm_runtime_factory_symbol = bad_internal_rows.factory_id;
    module.esm_runtime_internal_symbols = bad_internal_rows.internal_ids;
    try std.testing.expectError(
        error.InvalidEsmRuntimeInternalProducerSymbols,
        carryEsmRuntimeHelperSymbolsAfterReanalysis(&module, previous_with_bad_internal.semantic, allocator),
    );

    module.semantic = null;
    module.esm_runtime_factory_symbol = valid_rows.factory_id;
    module.esm_runtime_internal_symbols = valid_rows.internal_ids;
    try std.testing.expectError(
        error.MissingSemantic,
        carryEsmRuntimeHelperSymbolsAfterReanalysis(&module, valid_previous.semantic, allocator),
    );
}

test "ESM runtime helper reanalysis preserves factory and internal renames through production resync" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();
    const old_source = "const previous = 1;";
    const new_source = "let __esm = 1; let fn = 2; let res = 3; let e = 4; function __init() {} let f = 5;";
    var old_fixture = try runtimeHelperReanalysisTestFixture(allocator, old_source);
    const fresh_fixture = try runtimeHelperReanalysisTestFixture(allocator, new_source);
    const old_rows = try appendEsmRuntimeReanalysisTestRows(allocator, &old_fixture.semantic.symbols);

    var module = Module.init(@fromBackingInt(@intCast(23)), "esm-runtime-resync.js");
    module.source = new_source;
    module.ast = fresh_fixture.ast;
    module.parse_arena = &test_arena;
    module.semantic = old_fixture.semantic;
    module.esm_runtime_factory_symbol = old_rows.factory_id;
    module.esm_runtime_internal_symbols = old_rows.internal_ids;

    const rename_names = [_][]const u8{
        "__esm$factory",
        "fn$factory_parameter",
        "res$result_parameter",
        "e$catch_parameter",
        "__init$init_function",
        "f$factory_local",
    };
    var initial_renames: bundler_symbol.RenameTable = .{};
    defer initial_renames.deinit(std.testing.allocator);
    try initial_renames.put(
        std.testing.allocator,
        bundler_symbol.SymbolID.make(module.index, @backingInt(old_rows.factory_id)),
        rename_names[0],
    );
    for (esmRuntimeInternalRenameSlots(old_rows.internal_ids), 0..) |slot, index| {
        try initial_renames.put(
            std.testing.allocator,
            bundler_symbol.SymbolID.make(module.index, @backingInt(slot.symbol_id)),
            rename_names[index + 1],
        );
    }

    const test_context = .{
        .allocator = std.testing.allocator,
        .defines = &[_]@import("../../parser/scan_results.zig").DefineEntry{},
        .flow = false,
        .ignore_annotations = false,
        .minify_identifiers = false,
        .pure = &[_][]const u8{},
        .wrapper_symbols_registered = false,
        .wrap_kinds_finalized = true,
        .transform_options_base = .{ .minify_syntax = false },
    };
    try resyncAfterAstMutation(&test_context, &module, allocator, &initial_renames);

    const expected_factory_id: SemanticSymbolId = @fromBackingInt(@intCast(fresh_fixture.semantic.symbols.items.len));
    const expected_internal_ids = esmRuntimeReanalysisTestIdsAt(fresh_fixture.semantic.symbols.items.len + 1);
    try std.testing.expectEqual(expected_factory_id, module.esm_runtime_factory_symbol.?);
    try std.testing.expectEqualDeep(expected_internal_ids, module.esm_runtime_internal_symbols.?);
    try std.testing.expectEqualDeep(old_rows.factory_symbol, module.semantic.?.symbols.items[@backingInt(expected_factory_id)]);
    for (old_rows.internal_symbols, 0..) |expected_symbol, index| {
        try std.testing.expectEqualDeep(expected_symbol, module.semantic.?.symbols.items[fresh_fixture.semantic.symbols.items.len + index + 1]);
    }

    try std.testing.expectEqual(@as(u32, 6), module.pending_renames.count());
    const factory_key = bundler_symbol.SymbolID.make(module.index, @backingInt(expected_factory_id));
    try std.testing.expectEqualStrings(rename_names[0], module.pending_renames.get(factory_key).?);
    for (esmRuntimeInternalRenameSlots(expected_internal_ids), 0..) |slot, index| {
        const key = bundler_symbol.SymbolID.make(module.index, @backingInt(slot.symbol_id));
        try std.testing.expectEqualStrings(rename_names[index + 1], module.pending_renames.get(key).?);
    }
}

/// The graph-wide binary runtime helper name is collision-selected by its
/// producer ID. Carry it across semantic reanalysis through Module's exact
/// slot instead of matching its generated spelling and scope.
fn remapToBinaryRuntimeHelperRename(
    allocator: std.mem.Allocator,
    module_index: bundler_symbol.ModuleIndex,
    old_symbols: []const SemanticSymbol,
    new_symbols: []const SemanticSymbol,
    old_renames: []const ?[]const u8,
    old_id: ?SemanticSymbolId,
    new_id: ?SemanticSymbolId,
    rebuilt: *bundler_symbol.RenameTable,
) !void {
    const old_symbol_id = old_id orelse return;
    const new_symbol_id = new_id orelse return;
    if (!validToBinaryRuntimeHelperSymbol(old_symbol_id, old_symbols) or
        !validToBinaryRuntimeHelperSymbol(new_symbol_id, new_symbols)) return;
    const old_index: usize = @backingInt(old_symbol_id);
    if (old_index >= old_renames.len) return;
    const rename = old_renames[old_index] orelse return;
    const new_id_key = bundler_symbol.SymbolID.make(module_index, @backingInt(new_symbol_id));
    // Keep a NodeIndex mapping if it already supplied more specific evidence.
    if (rebuilt.get(new_id_key) != null) return;
    try rebuilt.put(allocator, new_id_key, rename);
}

test "toBinary runtime helper rename follows its exact producer slot" {
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(9));
    const old_id: SemanticSymbolId = @fromBackingInt(@as(u32, 0));
    const new_id: SemanticSymbolId = @fromBackingInt(@as(u32, 2));
    const old_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 1, "__toBinary"),
    };
    const new_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 4, "unrelated_helper"),
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 5, "__toBinary"),
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 7, "__toBinary"),
    };
    const old_renames: [1]?[]const u8 = .{"__toBinary$2"};
    var rebuilt: bundler_symbol.RenameTable = .{};
    defer rebuilt.deinit(std.testing.allocator);

    try remapGraphOwnedSyntheticRenames(
        std.testing.allocator,
        module_index,
        &old_symbols,
        &new_symbols,
        &old_renames,
        &rebuilt,
    );
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());
    try remapToBinaryRuntimeHelperRename(
        std.testing.allocator,
        module_index,
        &old_symbols,
        &new_symbols,
        &old_renames,
        old_id,
        new_id,
        &rebuilt,
    );

    const expected_id = bundler_symbol.SymbolID.make(module_index, 2);
    try std.testing.expectEqual(@as(u32, 1), rebuilt.count());
    try std.testing.expectEqualStrings("__toBinary$2", rebuilt.get(expected_id).?);
}

test "rename capture carries toBinary alias through its producer slot" {
    const allocator = std.testing.allocator;
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(12));
    const old_id: SemanticSymbolId = @fromBackingInt(@as(u32, 0));
    const new_id: SemanticSymbolId = @fromBackingInt(@as(u32, 2));
    var ast = ast_mod.Ast.init(allocator, "");
    defer ast.deinit();

    var module = Module.init(module_index, "entry.mjs");
    module.ast = ast;
    module.to_binary_runtime_symbol = old_id;
    defer module.pending_renames.deinit(allocator);

    var old_symbols: std.ArrayList(SemanticSymbol) = .empty;
    defer old_symbols.deinit(allocator);
    try old_symbols.append(allocator, graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 1, "__toBinary"));
    var new_symbols: std.ArrayList(SemanticSymbol) = .empty;
    defer new_symbols.deinit(allocator);
    try new_symbols.append(allocator, graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 5, "not_the_slot"));
    try new_symbols.append(allocator, graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 6, "__toBinary"));
    try new_symbols.append(allocator, graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 9, "__toBinary"));

    const old_sem = ModuleSemanticData{
        .symbols = old_symbols,
        .scopes = &.{},
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
    };
    const new_sem = ModuleSemanticData{
        .symbols = new_symbols,
        .scopes = &.{},
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
    };
    module.semantic = new_sem;
    module.to_binary_runtime_symbol = new_id;

    var rename_table: bundler_symbol.RenameTable = .{};
    defer rename_table.deinit(allocator);
    try rename_table.put(allocator, bundler_symbol.SymbolID.make(module_index, 0), "__toBinary$2");

    const resync_context = .{ .minify_identifiers = false, .allocator = allocator };
    try captureRenamesAfterResync(
        resync_context,
        &module,
        allocator,
        &rename_table,
        old_sem,
        null,
        null,
        old_id,
        null,
        null,
    );

    const new_key = bundler_symbol.SymbolID.make(module_index, 2);
    try std.testing.expectEqual(@as(u32, 1), module.pending_renames.count());
    try std.testing.expectEqualStrings("__toBinary$2", module.pending_renames.get(new_key).?);
    try std.testing.expect(module.pending_rename_capture_seen);
}

test "toBinary runtime helper remapping fails closed on hostile slot evidence" {
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(9));
    const old_id: SemanticSymbolId = @fromBackingInt(@as(u32, 0));
    const new_id: SemanticSymbolId = @fromBackingInt(@as(u32, 0));
    const old_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 1, "__toBinary"),
    };
    const new_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 8, "__toBinary"),
    };
    const renames: [1]?[]const u8 = .{"__toBinary$2"};
    var rebuilt: bundler_symbol.RenameTable = .{};
    defer rebuilt.deinit(std.testing.allocator);

    // 1-2: missing old/new producer slots.
    try remapToBinaryRuntimeHelperRename(std.testing.allocator, module_index, &old_symbols, &new_symbols, &renames, null, new_id, &rebuilt);
    try remapToBinaryRuntimeHelperRename(std.testing.allocator, module_index, &old_symbols, &new_symbols, &renames, old_id, null, &rebuilt);
    // 3-4: slots outside their corresponding semantic snapshots.
    const out_of_bounds: SemanticSymbolId = @fromBackingInt(@as(u32, 3));
    try remapToBinaryRuntimeHelperRename(std.testing.allocator, module_index, &old_symbols, &new_symbols, &renames, out_of_bounds, new_id, &rebuilt);
    try remapToBinaryRuntimeHelperRename(std.testing.allocator, module_index, &old_symbols, &new_symbols, &renames, old_id, out_of_bounds, &rebuilt);
    // 5-6: valid indexes that point at the wrong synthetic kind or declaration kind.
    var wrong_old_synthetic = old_symbols;
    wrong_old_synthetic[0] = graphOwnedSyntheticRenameTestSymbol(.cjs_runtime_factory, .variable_var, 1, "__toBinary");
    try remapToBinaryRuntimeHelperRename(std.testing.allocator, module_index, &wrong_old_synthetic, &new_symbols, &renames, old_id, new_id, &rebuilt);
    var wrong_new_kind = new_symbols;
    wrong_new_kind[0] = graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .function_decl, 8, "__toBinary");
    try remapToBinaryRuntimeHelperRename(std.testing.allocator, module_index, &old_symbols, &wrong_new_kind, &renames, old_id, new_id, &rebuilt);
    // 7-8: slot rows with a different runtime-helper spelling.
    var wrong_old_name = old_symbols;
    wrong_old_name[0] = graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 1, "__esm");
    try remapToBinaryRuntimeHelperRename(std.testing.allocator, module_index, &wrong_old_name, &new_symbols, &renames, old_id, new_id, &rebuilt);
    var wrong_new_name = new_symbols;
    wrong_new_name[0] = graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 8, "__esm");
    try remapToBinaryRuntimeHelperRename(std.testing.allocator, module_index, &old_symbols, &wrong_new_name, &renames, old_id, new_id, &rebuilt);
    // 9: the old slot exists, but the old rename snapshot has no matching row.
    const short_renames: [0]?[]const u8 = .{};
    try remapToBinaryRuntimeHelperRename(std.testing.allocator, module_index, &old_symbols, &new_symbols, &short_renames, old_id, new_id, &rebuilt);
    // 10: a missing rename value is not evidence to overwrite the new snapshot.
    const absent_rename: [1]?[]const u8 = .{null};
    try remapToBinaryRuntimeHelperRename(std.testing.allocator, module_index, &old_symbols, &new_symbols, &absent_rename, old_id, new_id, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    // 11: preserve a stronger exact-node anchor already recorded for the new ID.
    const expected_id = bundler_symbol.SymbolID.make(module_index, 0);
    try rebuilt.put(std.testing.allocator, expected_id, "from_node_anchor");
    try remapToBinaryRuntimeHelperRename(std.testing.allocator, module_index, &old_symbols, &new_symbols, &renames, old_id, new_id, &rebuilt);
    try std.testing.expectEqual(@as(u32, 1), rebuilt.count());
    try std.testing.expectEqualStrings("from_node_anchor", rebuilt.get(expected_id).?);
}

test "ESM runtime factory rename follows its exact producer slot" {
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(9));
    const old_id: SemanticSymbolId = @fromBackingInt(@as(u32, 0));
    const new_id: SemanticSymbolId = @fromBackingInt(@as(u32, 2));
    const old_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 1, "__esm"),
    };
    const new_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 5, "__esm"),
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 6, "other_helper"),
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 7, "__esm"),
    };
    const old_renames: [1]?[]const u8 = .{"__esm$2"};
    var rebuilt: bundler_symbol.RenameTable = .{};
    defer rebuilt.deinit(std.testing.allocator);

    try remapGraphOwnedSyntheticRenames(
        std.testing.allocator,
        module_index,
        &old_symbols,
        &new_symbols,
        &old_renames,
        &rebuilt,
    );
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());
    try remapEsmRuntimeFactoryRename(
        std.testing.allocator,
        module_index,
        &old_symbols,
        &new_symbols,
        &old_renames,
        old_id,
        new_id,
        &rebuilt,
    );

    const expected_id = bundler_symbol.SymbolID.make(module_index, 2);
    try std.testing.expectEqual(@as(u32, 1), rebuilt.count());
    try std.testing.expectEqualStrings("__esm$2", rebuilt.get(expected_id).?);
}

test "ESM runtime producer slots bypass the generic name and scope remapper" {
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(9));
    const old_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .parameter, 1, "fn"),
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 1, "__esm"),
    };
    const new_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .parameter, 1, "fn"),
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 1, "__esm"),
    };
    const renames: [2]?[]const u8 = .{ "fn_final", "__esm$2" };
    var rebuilt: bundler_symbol.RenameTable = .{};
    defer rebuilt.deinit(std.testing.allocator);

    try remapGraphOwnedSyntheticRenames(
        std.testing.allocator,
        module_index,
        &old_symbols,
        &new_symbols,
        &renames,
        &rebuilt,
    );

    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());
}

test "ESM runtime factory rename remapping rejects invalid slot evidence" {
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(9));
    const ids = [_]SemanticSymbolId{ @fromBackingInt(@as(u32, 0)), @fromBackingInt(@as(u32, 1)) };
    const symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 1, "__esm"),
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 2, "__esm"),
    };
    const renames: [2]?[]const u8 = .{ "__esm$2", "__esm$3" };
    var rebuilt: bundler_symbol.RenameTable = .{};
    defer rebuilt.deinit(std.testing.allocator);

    try remapEsmRuntimeFactoryRename(std.testing.allocator, module_index, &symbols, &symbols, &renames, null, ids[1], &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());
    try remapEsmRuntimeFactoryRename(std.testing.allocator, module_index, &symbols, &symbols, &renames, ids[0], null, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    const short_renames: [1]?[]const u8 = .{"__esm$2"};
    try remapEsmRuntimeFactoryRename(std.testing.allocator, module_index, &symbols, &symbols, &short_renames, ids[1], ids[0], &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var wrong_old_kind = symbols;
    wrong_old_kind[0] = graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .function_decl, 1, "__esm");
    try remapEsmRuntimeFactoryRename(std.testing.allocator, module_index, &wrong_old_kind, &symbols, &renames, ids[0], ids[1], &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var wrong_new_name = symbols;
    wrong_new_name[1] = graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 2, "__toBinary");
    try remapEsmRuntimeFactoryRename(std.testing.allocator, module_index, &symbols, &wrong_new_name, &renames, ids[0], ids[1], &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    const target_id = bundler_symbol.SymbolID.make(module_index, 1);
    try rebuilt.put(std.testing.allocator, target_id, "from_node_anchor");
    try remapEsmRuntimeFactoryRename(std.testing.allocator, module_index, &symbols, &symbols, &renames, ids[0], ids[1], &rebuilt);
    try std.testing.expectEqual(@as(u32, 1), rebuilt.count());
    try std.testing.expectEqualStrings("from_node_anchor", rebuilt.get(target_id).?);
}

test "ESM runtime internal renames follow exact producer slots across reanalysis" {
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(9));
    const old_ids: EsmRuntimeInternalSymbolIds = .{
        .factory_parameter = @fromBackingInt(@as(u32, 0)),
        .result_parameter = @fromBackingInt(@as(u32, 1)),
        .catch_parameter = @fromBackingInt(@as(u32, 2)),
        .init_function = @fromBackingInt(@as(u32, 3)),
        .factory_local = @fromBackingInt(@as(u32, 4)),
    };
    const new_ids: EsmRuntimeInternalSymbolIds = .{
        .factory_parameter = @fromBackingInt(@as(u32, 6)),
        .result_parameter = @fromBackingInt(@as(u32, 1)),
        .catch_parameter = @fromBackingInt(@as(u32, 5)),
        .init_function = @fromBackingInt(@as(u32, 3)),
        .factory_local = @fromBackingInt(@as(u32, 7)),
    };
    const names: runtime_helper_names.EsmRuntimeInternalNames = .{};
    const old_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .parameter, 1, names.factory_parameter),
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .parameter, 1, names.result_parameter),
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .catch_binding, 2, names.catch_parameter),
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .function_decl, 2, names.init_function),
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .variable_var, 2, names.factory_local),
    };
    const new_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .parameter, 12, "decoy"),
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .parameter, 7, names.result_parameter),
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .catch_binding, 8, names.catch_parameter),
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .function_decl, 9, names.init_function),
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .variable_var, 10, names.factory_local),
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .catch_binding, 11, names.catch_parameter),
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .parameter, 6, names.factory_parameter),
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .variable_var, 13, names.factory_local),
    };
    const old_renames: [5]?[]const u8 = .{
        "factory_parameter_final",
        "result_parameter_final",
        "catch_parameter_final",
        "init_function_final",
        "factory_local_final",
    };
    var rebuilt: bundler_symbol.RenameTable = .{};
    defer rebuilt.deinit(std.testing.allocator);

    try remapGraphOwnedSyntheticRenames(
        std.testing.allocator,
        module_index,
        &old_symbols,
        &new_symbols,
        &old_renames,
        &rebuilt,
    );
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());
    try remapEsmRuntimeInternalRenames(
        std.testing.allocator,
        module_index,
        &old_symbols,
        &new_symbols,
        &old_renames,
        old_ids,
        new_ids,
        &rebuilt,
    );

    try std.testing.expectEqual(@as(u32, 5), rebuilt.count());
    try std.testing.expectEqualStrings("factory_parameter_final", rebuilt.get(bundler_symbol.SymbolID.make(module_index, 6)).?);
    try std.testing.expectEqualStrings("result_parameter_final", rebuilt.get(bundler_symbol.SymbolID.make(module_index, 1)).?);
    try std.testing.expectEqualStrings("catch_parameter_final", rebuilt.get(bundler_symbol.SymbolID.make(module_index, 5)).?);
    try std.testing.expectEqualStrings("init_function_final", rebuilt.get(bundler_symbol.SymbolID.make(module_index, 3)).?);
    try std.testing.expectEqualStrings("factory_local_final", rebuilt.get(bundler_symbol.SymbolID.make(module_index, 7)).?);
}

test "ESM runtime internal rename remapping fails closed on invalid slot evidence" {
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(9));
    const ids: EsmRuntimeInternalSymbolIds = .{
        .factory_parameter = @fromBackingInt(@as(u32, 0)),
        .result_parameter = @fromBackingInt(@as(u32, 1)),
        .catch_parameter = @fromBackingInt(@as(u32, 2)),
        .init_function = @fromBackingInt(@as(u32, 3)),
        .factory_local = @fromBackingInt(@as(u32, 4)),
    };
    const names: runtime_helper_names.EsmRuntimeInternalNames = .{};
    const symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .parameter, 1, names.factory_parameter),
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .parameter, 1, names.result_parameter),
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .catch_binding, 2, names.catch_parameter),
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .function_decl, 2, names.init_function),
        graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .variable_var, 2, names.factory_local),
    };
    const renames: [5]?[]const u8 = .{ "fn_final", "res_final", "e_final", "init_final", "f_final" };
    var rebuilt: bundler_symbol.RenameTable = .{};
    defer rebuilt.deinit(std.testing.allocator);

    try remapEsmRuntimeInternalRenames(std.testing.allocator, module_index, &symbols, &symbols, &renames, null, ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());
    try remapEsmRuntimeInternalRenames(std.testing.allocator, module_index, &symbols, &symbols, &renames, ids, null, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    const short_renames: [4]?[]const u8 = .{ "fn_final", "res_final", "e_final", "init_final" };
    try remapEsmRuntimeInternalRenames(std.testing.allocator, module_index, &symbols, &symbols, &short_renames, ids, ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var duplicate_old = ids;
    duplicate_old.result_parameter = duplicate_old.factory_parameter;
    try remapEsmRuntimeInternalRenames(std.testing.allocator, module_index, &symbols, &symbols, &renames, duplicate_old, ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var duplicate_new = ids;
    duplicate_new.factory_local = duplicate_new.init_function;
    try remapEsmRuntimeInternalRenames(std.testing.allocator, module_index, &symbols, &symbols, &renames, ids, duplicate_new, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var out_of_bounds = ids;
    out_of_bounds.catch_parameter = @fromBackingInt(@as(u32, 5));
    try remapEsmRuntimeInternalRenames(std.testing.allocator, module_index, &symbols, &symbols, &renames, ids, out_of_bounds, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var wrong_old_kind = symbols;
    wrong_old_kind[0] = graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .function_decl, 1, names.factory_parameter);
    try remapEsmRuntimeInternalRenames(std.testing.allocator, module_index, &wrong_old_kind, &symbols, &renames, ids, ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var wrong_new_synthetic = symbols;
    wrong_new_synthetic[4] = graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 2, names.factory_local);
    try remapEsmRuntimeInternalRenames(std.testing.allocator, module_index, &symbols, &wrong_new_synthetic, &renames, ids, ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    var wrong_new_name = symbols;
    wrong_new_name[4] = graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, .variable_var, 2, "not_factory_local");
    try remapEsmRuntimeInternalRenames(std.testing.allocator, module_index, &symbols, &wrong_new_name, &renames, ids, ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    const factory_id = bundler_symbol.SymbolID.make(module_index, 0);
    try rebuilt.put(std.testing.allocator, factory_id, "node_anchor_final");
    try remapEsmRuntimeInternalRenames(std.testing.allocator, module_index, &symbols, &symbols, &renames, ids, ids, &rebuilt);
    try std.testing.expectEqual(@as(u32, 5), rebuilt.count());
    try std.testing.expectEqualStrings("node_anchor_final", rebuilt.get(factory_id).?);
}

test "graph-owned singleton synthetic renames follow producer identity" {
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(7));
    const expected_id = bundler_symbol.SymbolID.make(module_index, 1);
    var rebuilt: bundler_symbol.RenameTable = .{};
    defer rebuilt.deinit(std.testing.allocator);

    const singleton_kinds = [_]struct { synthetic: SemanticSyntheticKind, symbol: SemanticSymbolKind }{
        .{ .synthetic = .cjs_exports, .symbol = .variable_var },
        .{ .synthetic = .cjs_require, .symbol = .function_decl },
        .{ .synthetic = .esm_init, .symbol = .function_decl },
        .{ .synthetic = .cjs_wrapper_exports_parameter, .symbol = .parameter },
        .{ .synthetic = .cjs_wrapper_module_parameter, .symbol = .parameter },
        .{ .synthetic = .cjs_runtime_factory, .symbol = .variable_var },
    };
    const final_rename: [1]?[]const u8 = .{"module_owned_final"};
    for (singleton_kinds) |singleton| {
        const old_symbols = [_]SemanticSymbol{
            graphOwnedSyntheticRenameTestSymbol(singleton.synthetic, singleton.symbol, 1, "producer_before"),
        };
        const new_symbols = [_]SemanticSymbol{
            .{
                .name = Span.EMPTY,
                .kind = .variable_let,
                .scope_id = @fromBackingInt(@intCast(0)),
                .declaration_span = Span.EMPTY,
            },
            graphOwnedSyntheticRenameTestSymbol(singleton.synthetic, singleton.symbol, 1, "producer_after"),
        };

        try remapGraphOwnedSyntheticRenames(
            std.testing.allocator,
            module_index,
            &old_symbols,
            &new_symbols,
            &final_rename,
            &rebuilt,
        );

        try std.testing.expectEqual(@as(u32, 1), rebuilt.count());
        try std.testing.expectEqualStrings(
            "module_owned_final",
            rebuilt.get(expected_id) orelse return error.TestExpectedEqual,
        );
        try std.testing.expect(rebuilt.get(bundler_symbol.SymbolID.make(module_index, 0)) == null);
        rebuilt.clear();
    }

    const old_symbols_scope_change = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.cjs_exports, .variable_var, 1, "exports_stable"),
    };
    const new_symbols_scope_change = [_]SemanticSymbol{
        .{
            .name = Span.EMPTY,
            .kind = .variable_let,
            .scope_id = @fromBackingInt(@intCast(0)),
            .declaration_span = Span.EMPTY,
        },
        graphOwnedSyntheticRenameTestSymbol(.cjs_exports, .variable_var, 5, "exports_stable"),
    };
    const scope_change_rename: [1]?[]const u8 = .{"exports_scope_final"};
    try remapGraphOwnedSyntheticRenames(
        std.testing.allocator,
        module_index,
        &old_symbols_scope_change,
        &new_symbols_scope_change,
        &scope_change_rename,
        &rebuilt,
    );
    try std.testing.expectEqualStrings(
        "exports_scope_final",
        rebuilt.get(expected_id) orelse return error.TestExpectedEqual,
    );
}

test "graph-owned singleton synthetic renames reject ambiguous mappings" {
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(7));
    const old_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.cjs_exports, .variable_var, 1, "exports_before_a"),
        graphOwnedSyntheticRenameTestSymbol(.cjs_exports, .variable_var, 2, "exports_before_b"),
    };
    const new_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.cjs_exports, .variable_var, 5, "exports_after"),
    };
    const old_renames: [2]?[]const u8 = .{ "exports_final_a", "exports_final_b" };
    var rebuilt: bundler_symbol.RenameTable = .{};
    defer rebuilt.deinit(std.testing.allocator);

    try remapGraphOwnedSyntheticRenames(
        std.testing.allocator,
        module_index,
        &old_symbols,
        &new_symbols,
        &old_renames,
        &rebuilt,
    );

    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    rebuilt.clear();
    const old_unique = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.cjs_exports, .variable_var, 1, "exports_before"),
    };
    const new_ambiguous = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.cjs_exports, .variable_var, 5, "exports_after_a"),
        graphOwnedSyntheticRenameTestSymbol(.cjs_exports, .variable_var, 6, "exports_after_b"),
    };
    const one_old_rename: [1]?[]const u8 = .{"exports_final"};
    try remapGraphOwnedSyntheticRenames(
        std.testing.allocator,
        module_index,
        &old_unique,
        &new_ambiguous,
        &one_old_rename,
        &rebuilt,
    );
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());
}

test "graph-owned synthetic renames preserve non-singleton and kind boundaries" {
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(7));
    const old_helper = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 1, "__helper_before"),
    };
    const renamed_helper = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 1, "__helper_after"),
    };
    const old_rename: [1]?[]const u8 = .{"__helper_final"};
    var rebuilt: bundler_symbol.RenameTable = .{};
    defer rebuilt.deinit(std.testing.allocator);

    try remapGraphOwnedSyntheticRenames(
        std.testing.allocator,
        module_index,
        &old_helper,
        &renamed_helper,
        &old_rename,
        &rebuilt,
    );
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    const old_exports = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.cjs_exports, .variable_var, 1, "exports"),
    };
    const wrong_synthetic_kind = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.cjs_require, .variable_var, 1, "exports"),
    };
    try remapGraphOwnedSyntheticRenames(
        std.testing.allocator,
        module_index,
        &old_exports,
        &wrong_synthetic_kind,
        &old_rename,
        &rebuilt,
    );
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());

    const wrong_symbol_kind = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.cjs_exports, .function_decl, 1, "exports"),
    };
    try remapGraphOwnedSyntheticRenames(
        std.testing.allocator,
        module_index,
        &old_exports,
        &wrong_symbol_kind,
        &old_rename,
        &rebuilt,
    );
    try std.testing.expectEqual(@as(u32, 0), rebuilt.count());
}

test "graph-owned synthetic rename does not replace an existing exact mapping" {
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(7));
    const old_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.cjs_exports, .variable_var, 1, "exports"),
    };
    const new_symbols = [_]SemanticSymbol{
        graphOwnedSyntheticRenameTestSymbol(.cjs_exports, .variable_var, 5, "exports"),
    };
    const old_rename: [1]?[]const u8 = .{"from_previous_snapshot"};
    const target_id = bundler_symbol.SymbolID.make(module_index, 0);
    var rebuilt: bundler_symbol.RenameTable = .{};
    defer rebuilt.deinit(std.testing.allocator);
    try rebuilt.put(std.testing.allocator, target_id, "from_node_anchor");

    try remapGraphOwnedSyntheticRenames(
        std.testing.allocator,
        module_index,
        &old_symbols,
        &new_symbols,
        &old_rename,
        &rebuilt,
    );

    try std.testing.expectEqual(@as(u32, 1), rebuilt.count());
    try std.testing.expectEqualStrings(
        "from_node_anchor",
        rebuilt.get(target_id) orelse return error.TestExpectedEqual,
    );
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
    old_cjs_runtime_internal_symbols: ?CjsRuntimeInternalSymbolIds,
    new_cjs_runtime_internal_symbols: ?CjsRuntimeInternalSymbolIds,
    old_esm_runtime_internal_symbols: ?EsmRuntimeInternalSymbolIds,
    new_esm_runtime_internal_symbols: ?EsmRuntimeInternalSymbolIds,
    old_to_binary_runtime_symbol: ?SemanticSymbolId,
    new_to_binary_runtime_symbol: ?SemanticSymbolId,
    old_esm_runtime_factory_symbol: ?SemanticSymbolId,
    new_esm_runtime_factory_symbol: ?SemanticSymbolId,
    old_esm_interop_runtime_helper_symbols: ?EsmInteropRuntimeHelperSymbolIds,
    new_esm_interop_runtime_helper_symbols: ?EsmInteropRuntimeHelperSymbolIds,
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
    try remapGraphOwnedSyntheticRenames(
        arena,
        module.index,
        old_sem.symbols.items,
        new_sem.symbols.items,
        old_renames,
        &rebuilt,
    );
    try remapCjsRuntimeInternalRenames(
        arena,
        module.index,
        old_sem.symbols.items,
        new_sem.symbols.items,
        old_renames,
        old_cjs_runtime_internal_symbols,
        new_cjs_runtime_internal_symbols,
        &rebuilt,
    );
    try remapEsmRuntimeInternalRenames(
        arena,
        module.index,
        old_sem.symbols.items,
        new_sem.symbols.items,
        old_renames,
        old_esm_runtime_internal_symbols,
        new_esm_runtime_internal_symbols,
        &rebuilt,
    );
    try remapEsmRuntimeFactoryRename(
        arena,
        module.index,
        old_sem.symbols.items,
        new_sem.symbols.items,
        old_renames,
        old_esm_runtime_factory_symbol,
        new_esm_runtime_factory_symbol,
        &rebuilt,
    );
    try remapToBinaryRuntimeHelperRename(
        arena,
        module.index,
        old_sem.symbols.items,
        new_sem.symbols.items,
        old_renames,
        old_to_binary_runtime_symbol,
        new_to_binary_runtime_symbol,
        &rebuilt,
    );
    try remapEsmInteropRuntimeHelperRenames(
        arena,
        module.index,
        old_sem.symbols.items,
        new_sem.symbols.items,
        old_renames,
        old_esm_interop_runtime_helper_symbols,
        new_esm_interop_runtime_helper_symbols,
        &rebuilt,
    );
    module.pending_renames = rebuilt;
    module.pending_rename_capture_seen = true;
}

test "rename capture carries ESM factory alias through the production handoff" {
    const allocator = std.testing.allocator;
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(12));
    const old_factory_id: SemanticSymbolId = @fromBackingInt(@as(u32, 0));
    const new_factory_id: SemanticSymbolId = @fromBackingInt(@as(u32, 1));
    const old_internal_ids: EsmRuntimeInternalSymbolIds = .{
        .factory_parameter = @fromBackingInt(@as(u32, 1)),
        .result_parameter = @fromBackingInt(@as(u32, 2)),
        .catch_parameter = @fromBackingInt(@as(u32, 3)),
        .init_function = @fromBackingInt(@as(u32, 4)),
        .factory_local = @fromBackingInt(@as(u32, 5)),
    };
    const new_internal_ids: EsmRuntimeInternalSymbolIds = .{
        .factory_parameter = @fromBackingInt(@as(u32, 2)),
        .result_parameter = @fromBackingInt(@as(u32, 3)),
        .catch_parameter = @fromBackingInt(@as(u32, 4)),
        .init_function = @fromBackingInt(@as(u32, 5)),
        .factory_local = @fromBackingInt(@as(u32, 6)),
    };
    var ast = ast_mod.Ast.init(allocator, "");
    defer ast.deinit();

    var module = Module.init(module_index, "entry.mjs");
    module.ast = ast;
    defer module.pending_renames.deinit(allocator);

    var old_symbols: std.ArrayList(SemanticSymbol) = .empty;
    defer old_symbols.deinit(allocator);
    try old_symbols.append(allocator, graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 1, "__esm"));
    for (esmRuntimeInternalRenameSlots(old_internal_ids), 0..) |slot, index| {
        try old_symbols.append(allocator, graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, slot.symbol_kind, @intCast(index + 2), slot.synthetic_name));
    }
    var new_symbols: std.ArrayList(SemanticSymbol) = .empty;
    defer new_symbols.deinit(allocator);
    try new_symbols.append(allocator, graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 5, "decoy"));
    try new_symbols.append(allocator, graphOwnedSyntheticRenameTestSymbol(.bundler_runtime_helper, .variable_var, 6, "__esm"));
    for (esmRuntimeInternalRenameSlots(new_internal_ids), 0..) |slot, index| {
        try new_symbols.append(allocator, graphOwnedSyntheticRenameTestSymbol(.esm_runtime_internal_local, slot.symbol_kind, @intCast(index + 7), slot.synthetic_name));
    }

    const old_sem = ModuleSemanticData{
        .symbols = old_symbols,
        .scopes = &.{},
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
    };
    const new_sem = ModuleSemanticData{
        .symbols = new_symbols,
        .scopes = &.{},
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
    };
    var rename_table: bundler_symbol.RenameTable = .{};
    defer rename_table.deinit(allocator);
    try rename_table.put(allocator, bundler_symbol.SymbolID.make(module_index, 0), "__esm$2");
    const internal_rename_names = [_][]const u8{
        "factory_parameter_final",
        "result_parameter_final",
        "catch_parameter_final",
        "init_function_final",
        "factory_local_final",
    };
    for (internal_rename_names, 0..) |name, index| {
        try rename_table.put(allocator, bundler_symbol.SymbolID.make(module_index, index + 1), name);
    }

    try captureRenamesToPending(
        &module,
        &rename_table,
        old_sem,
        &new_sem,
        null,
        null,
        old_internal_ids,
        new_internal_ids,
        null,
        null,
        old_factory_id,
        new_factory_id,
        null,
        null,
        allocator,
        allocator,
    );

    const new_key = bundler_symbol.SymbolID.make(module_index, 1);
    try std.testing.expectEqual(@as(u32, 6), module.pending_renames.count());
    try std.testing.expectEqualStrings("__esm$2", module.pending_renames.get(new_key).?);
    for (internal_rename_names, 0..) |name, index| {
        const new_internal_key = bundler_symbol.SymbolID.make(module_index, index + 2);
        try std.testing.expectEqualStrings(name, module.pending_renames.get(new_internal_key).?);
    }
    try std.testing.expect(module.pending_rename_capture_seen);
}

/// Semantic reanalysis rebuilds source rows and drops graph-owned runtime helper rows.
/// Carry the previous exact producer slot into the new table instead of finding a
/// replacement row by its generated spelling.
fn carryToBinaryRuntimeHelperSymbolAfterReanalysis(
    module: *Module,
    previous_semantic: ?ModuleSemanticData,
    allocator: std.mem.Allocator,
) !void {
    const previous = previous_semantic orelse return;
    const old_id = module.to_binary_runtime_symbol orelse return;
    if (old_id.isNone()) return error.InvalidToBinaryRuntimeHelperProducerSymbol;
    const old_index: usize = @intCast(@backingInt(old_id));
    if (old_index >= previous.symbols.items.len) return error.InvalidToBinaryRuntimeHelperProducerSymbol;
    const old_symbol = previous.symbols.items[old_index];
    if (old_symbol.synthetic_kind != .bundler_runtime_helper or
        old_symbol.kind != .variable_var or
        !std.mem.eql(u8, old_symbol.synthetic_name, "__toBinary"))
    {
        return error.InvalidToBinaryRuntimeHelperProducerSymbol;
    }

    const current = if (module.semantic) |*semantic| semantic else return error.MissingSemantic;
    if (current.symbols.items.len >= @as(usize, std.math.maxInt(u32)))
        return error.RuntimeHelperSymbolTableOverflow;
    const new_id: SemanticSymbolId = @fromBackingInt(@intCast(current.symbols.items.len));
    try current.symbols.append(allocator, old_symbol);
    module.to_binary_runtime_symbol = new_id;
}

/// Reanalysis replaces source semantic rows but Module owns the graph-level
/// ESM factory and all five lexical rows in its raw runtime template. Carry the
/// complete producer group by its typed slots so later rename capture never
/// has to rediscover any row by spelling.
fn carryEsmRuntimeHelperSymbolsAfterReanalysis(
    module: *Module,
    previous_semantic: ?ModuleSemanticData,
    allocator: std.mem.Allocator,
) !void {
    const previous = previous_semantic orelse return;
    const old_factory_id = module.esm_runtime_factory_symbol orelse {
        if (module.esm_runtime_internal_symbols != null) return error.MissingEsmRuntimeFactoryProducerSymbol;
        return;
    };
    if (!validEsmRuntimeFactorySymbol(old_factory_id, previous.symbols.items))
        return error.InvalidEsmRuntimeFactoryProducerSymbol;

    const old_internal_ids = module.esm_runtime_internal_symbols orelse
        return error.MissingEsmRuntimeInternalProducerSymbols;
    const old_internal_slots = esmRuntimeInternalRenameSlots(old_internal_ids);
    if (!validEsmRuntimeInternalRenameSlots(old_internal_slots, previous.symbols.items))
        return error.InvalidEsmRuntimeInternalProducerSymbols;
    for (old_internal_slots) |slot| {
        if (slot.symbol_id == old_factory_id) return error.InvalidEsmRuntimeProducerSlotOverlap;
    }

    const current = if (module.semantic) |*semantic| semantic else return error.MissingSemantic;
    const rows_to_append: usize = 1 + old_internal_slots.len;
    const max_symbol_count: usize = std.math.maxInt(u32);
    if (current.symbols.items.len > max_symbol_count - rows_to_append)
        return error.RuntimeHelperSymbolTableOverflow;

    const old_factory_symbol = previous.symbols.items[@backingInt(old_factory_id)];
    const new_factory_id: SemanticSymbolId = @fromBackingInt(@intCast(current.symbols.items.len));
    try current.symbols.append(allocator, old_factory_symbol);

    var new_internal_ids: [5]SemanticSymbolId = undefined;
    for (old_internal_slots, 0..) |slot, index| {
        const old_index: usize = @backingInt(slot.symbol_id);
        const new_id: SemanticSymbolId = @fromBackingInt(@intCast(current.symbols.items.len));
        try current.symbols.append(allocator, previous.symbols.items[old_index]);
        new_internal_ids[index] = new_id;
    }

    module.esm_runtime_factory_symbol = new_factory_id;
    module.esm_runtime_internal_symbols = .{
        .factory_parameter = new_internal_ids[0],
        .result_parameter = new_internal_ids[1],
        .catch_parameter = new_internal_ids[2],
        .init_function = new_internal_ids[3],
        .factory_local = new_internal_ids[4],
    };
}

/// Semantic reanalysis replaces source rows but Module owns the graph-wide raw
/// ESM interop helper bindings. Carry their exact producer slots as a group so
/// the linker never rediscovers them by helper spelling.
fn carryEsmInteropRuntimeHelperSymbolsAfterReanalysis(
    module: *Module,
    previous_semantic: ?ModuleSemanticData,
    allocator: std.mem.Allocator,
) !void {
    const previous = previous_semantic orelse return;
    const old_ids = module.esm_interop_runtime_helper_symbols orelse {
        if (hasEsmInteropRuntimeHelperRows(previous.symbols.items)) return error.MissingEsmInteropRuntimeProducerSymbols;
        return;
    };
    const old_slots = esmInteropRuntimeHelperSlots(old_ids);
    if (!validEsmInteropRuntimeHelperSlots(old_slots, previous.symbols.items))
        return error.InvalidEsmInteropRuntimeProducerSymbols;

    const current = if (module.semantic) |*semantic| semantic else return error.MissingSemantic;
    const rows_to_append: usize = old_slots.len;
    const max_symbol_count: usize = std.math.maxInt(u32);
    if (current.symbols.items.len > max_symbol_count - rows_to_append)
        return error.RuntimeHelperSymbolTableOverflow;

    const start_len = current.symbols.items.len;
    errdefer current.symbols.items.len = start_len;
    var new_slots: [runtime_helper_names.ESM_INTEROP_RUNTIME_HELPERS.len]SemanticSymbolId = undefined;
    for (old_slots, 0..) |old_id, index| {
        const old_index: usize = @backingInt(old_id);
        new_slots[index] = @fromBackingInt(@intCast(current.symbols.items.len));
        try current.symbols.append(allocator, previous.symbols.items[old_index]);
    }
    module.esm_interop_runtime_helper_symbols = esmInteropRuntimeHelperIdsFromSlots(new_slots);
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
    const namespace_parameter_names = if (previous_semantic) |*semantic|
        try SemanticAnalyzer.collectNamespaceIifeParameterNames(
            arena_alloc,
            ast,
            semantic.symbols.items,
            &semantic.scope_owner_map,
        )
    else
        SemanticAnalyzer.NamespaceIifeParameterNames.empty;
    analyzer.preserved_namespace_iife_parameter_names = &namespace_parameter_names;
    {
        var semantic_scope = profile.begin(.graph_resync_semantic);
        defer semantic_scope.end();

        // Reanalysis must use the source module's resolved program mode. In
        // particular, a `.cjs` module can be a sloppy script even when it is
        // bundled beside ESM; forcing strict mode makes the emitter add a
        // file-level directive that makes retained `with` statements invalid.
        if (previous_semantic) |semantic| {
            if (semantic.scopes.len > 0) {
                const root_scope = semantic.scopes[0];
                analyzer.is_strict_mode = root_scope.is_strict;
                analyzer.is_module = root_scope.kind == .module;
            } else {
                // Empty semantic scopes are only expected after an earlier
                // analysis failure. Preserve the previous conservative mode.
                analyzer.is_strict_mode = true;
                analyzer.is_module = true;
            }
        } else {
            // A successful parse normally always supplies the prior root
            // scope. Keep the old fallback for malformed or incomplete modules.
            analyzer.is_strict_mode = true;
            analyzer.is_module = true;
        }
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
            const reachable_post_graph_nodes: ?[]bool = if (ast.transformed_root) |root| blk: {
                const reachable = try ast_walk.collectReachableNodeIndicesFrom(arena_alloc, ast, root);
                const bitmap = try arena_alloc.alloc(bool, ast.nodes.items.len);
                @memset(bitmap, false);
                for (reachable) |raw| bitmap[raw] = true;
                break :blk bitmap;
            } else null;
            for (cache.preserved_class_name_nodes) |raw| {
                if (raw >= analyzer.symbol_ids.items.len or raw >= ast.nodes.items.len or
                    ast.nodes.items[raw].tag != .binding_identifier) continue;
                const id = analyzer.symbol_ids.items[raw] orelse continue;
                if (id >= analyzer.symbols.items.len) continue;
                analyzer.symbols.items[id].decl_flags.preserve_class_name = true;
            }
            for (cache.worklet_factory_local_bindings) |factory_binding| {
                const raw = factory_binding.node_index;
                if (raw >= analyzer.symbol_ids.items.len or raw >= ast.nodes.items.len or
                    ast.nodes.items[raw].tag != .binding_identifier)
                    return error.InvalidWorkletFactoryBindingProvenance;
                const id = analyzer.symbol_ids.items[raw] orelse continue;
                if (id >= analyzer.symbols.items.len) return error.InvalidWorkletFactorySymbolId;
                const symbol = &analyzer.symbols.items[id];
                if (symbol.synthetic_kind != null and symbol.synthetic_kind != .worklet_factory_local)
                    return error.WorkletFactoryBindingKindConflict;
                symbol.synthetic_kind = .worklet_factory_local;
                symbol.synthetic_name = ast.getText(ast.nodes.items[raw].data.string_ref);
                symbol.output_name_hint = factory_binding.output_name_hint;
            }
            for (cache.post_graph_output_bindings) |output_binding| {
                const raw = output_binding.node_index;
                if (raw >= analyzer.symbol_ids.items.len or raw >= ast.nodes.items.len or
                    ast.nodes.items[raw].tag != .binding_identifier)
                    return error.InvalidPostGraphOutputBindingProvenance;
                // Minification can remove an unused generated binding while
                // leaving its old node index and producer sidecar in the AST
                // allocation. Do not restore identity for an unreachable
                // node, but keep failing closed when a live binding lost its
                // analyzer SymbolId.
                if (reachable_post_graph_nodes) |reachable| {
                    if (!reachable[raw]) continue;
                }
                const id = analyzer.symbol_ids.items[raw] orelse return error.MissingPostGraphOutputBindingSymbol;
                if (id >= analyzer.symbols.items.len) return error.InvalidPostGraphOutputSymbolId;
                const symbol = &analyzer.symbols.items[id];
                if (!isPostGraphOutputBindingKind(output_binding.synthetic_kind, output_binding.binding_kind) or
                    !isPostGraphOutputBindingKind(output_binding.synthetic_kind, symbol.kind) or
                    symbol.scope_id.isNone()) return error.InvalidPostGraphOutputBindingKind;
                if (symbol.synthetic_kind != null and symbol.synthetic_kind != output_binding.synthetic_kind)
                    return error.PostGraphOutputBindingKindConflict;
                if (!isValidPostGraphOutputNameHint(output_binding.synthetic_kind, output_binding.output_name_hint)) {
                    return error.InvalidPostGraphOutputNameKind;
                }
                symbol.synthetic_kind = output_binding.synthetic_kind;
                symbol.synthetic_name = ast.getText(ast.nodes.items[raw].data.string_ref);
                symbol.output_name_hint = output_binding.output_name_hint;
            }
            for (cache.runtime_helper_import_output_bindings) |output_binding| {
                const raw = output_binding.node_index;
                if (raw >= analyzer.symbol_ids.items.len or raw >= ast.nodes.items.len)
                    return error.InvalidRuntimeHelperImportProvenance;
                const local = ast.nodes.items[raw];
                if (local.tag != .identifier_reference and local.tag != .import_default_specifier)
                    return error.InvalidRuntimeHelperImportProvenance;
                const id = analyzer.symbol_ids.items[raw] orelse return error.MissingRuntimeHelperImportSymbol;
                if (id >= analyzer.symbols.items.len) return error.InvalidRuntimeHelperImportSymbolId;
                const symbol = &analyzer.symbols.items[id];
                if (symbol.kind != .import_binding or symbol.scope_id.isNone())
                    return error.InvalidRuntimeHelperImportBindingKind;
                if (symbol.synthetic_kind != null and symbol.synthetic_kind != .runtime_helper_import)
                    return error.RuntimeHelperImportSyntheticKindConflict;
                if (output_binding.output_name_hint.len == 0 or
                    !std.mem.eql(u8, ast.getText(local.data.string_ref), output_binding.output_name_hint))
                    return error.InvalidRuntimeHelperImportOutputHint;
                symbol.synthetic_kind = .runtime_helper_import;
                symbol.synthetic_name = ast.getText(local.data.string_ref);
                symbol.output_name_hint = output_binding.output_name_hint;
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
        try carryToBinaryRuntimeHelperSymbolAfterReanalysis(module, previous_semantic, arena_alloc);
        try carryEsmRuntimeHelperSymbolsAfterReanalysis(module, previous_semantic, arena_alloc);
        try carryEsmInteropRuntimeHelperSymbolsAfterReanalysis(module, previous_semantic, arena_alloc);
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
    previous_cjs_runtime_internal_symbols: ?CjsRuntimeInternalSymbolIds,
    previous_esm_runtime_internal_symbols: ?EsmRuntimeInternalSymbolIds,
    previous_to_binary_runtime_symbol: ?SemanticSymbolId,
    previous_esm_runtime_factory_symbol: ?SemanticSymbolId,
    previous_esm_interop_runtime_helper_symbols: ?EsmInteropRuntimeHelperSymbolIds,
) !void {
    if (self.minify_identifiers) return;
    const rt = rename_table orelse return;
    const old_sem = previous_semantic orelse return;
    const new_sem = if (module.semantic) |*sem| sem else return;
    try captureRenamesToPending(
        module,
        rt,
        old_sem,
        new_sem,
        previous_cjs_runtime_internal_symbols,
        module.cjs_runtime_internal_symbols,
        previous_esm_runtime_internal_symbols,
        module.esm_runtime_internal_symbols,
        previous_to_binary_runtime_symbol,
        module.to_binary_runtime_symbol,
        previous_esm_runtime_factory_symbol,
        module.esm_runtime_factory_symbol,
        previous_esm_interop_runtime_helper_symbols,
        module.esm_interop_runtime_helper_symbols,
        self.allocator,
        arena_alloc,
    );
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
    const module_scope_id: ?ScopeId = if (sem.scopes.len > 0) @fromBackingInt(@as(u32, 0)) else null;
    try binding_scanner_mod.populateSyntheticSymbolsWithOwnerScope(
        &module.alias_table.?,
        module.index,
        module.export_bindings,
        &sem.symbols,
        arena_alloc,
        scope0,
        sem.symbol_ids,
        module_scope_id,
    );
}

/// Numeric const materialization replaces identifier reads and may let minify fold
/// expressions, but it does not add/remove import or export declarations. Keep the
/// expensive syntax-level scanners intact for general transforms and use this path
/// only when the caller owns that invariant.
fn isMaterializedPrimitiveLiteral(tag: NodeTag) bool {
    return switch (tag) {
        .boolean_literal, .null_literal, .numeric_literal => true,
        else => false,
    };
}

/// Numeric post-pass with no syntax folding has only replaced identifier leaves
/// with primitive literals. Keep all surviving semantic identities and remove
/// references by their exact NodeIndex through SemanticEditor; a full analyzer
/// pass here would rebuild SymbolIds and require a rename carry-over.
pub fn resyncAfterConstMaterializationRetainingGraph(
    self: anytype,
    module: *Module,
    arena_alloc: std.mem.Allocator,
    materialized_nodes: []const ast_mod.NodeIndex,
) !void {
    var resync_scope = profile.begin(.graph_resync);
    defer resync_scope.end();
    var const_scope = profile.begin(.graph_resync_const);
    defer const_scope.end();

    const ast = &(module.ast orelse return error.MissingAst);
    const semantic = if (module.semantic) |*sem| sem else return error.MissingSemantic;
    var editor = try semantic.beginEdit(arena_alloc, ast);
    defer editor.deinit();

    if (materialized_nodes.len == 0) return error.MaterializedReferenceMissing;
    for (materialized_nodes) |node_index| {
        if (node_index.isNone() or @backingInt(node_index) >= ast.nodes.items.len) {
            return error.InvalidMaterializedNode;
        }
        if (!isMaterializedPrimitiveLiteral(ast.nodes.items[@backingInt(node_index)].tag)) {
            return error.InvalidMaterializedNode;
        }
    }
    // The materializer supplies exact read sites. Remove them in one stable
    // compaction pass instead of reindexing the remaining references per node.
    try editor.removeReferences(materialized_nodes);

    semantic.applyEdit(try editor.finish());
    if (module.transform_cache) |*cache| cache.symbol_ids = semantic.symbol_ids;
    try refreshStableBindingRefsFromSemanticGraph(self, module, arena_alloc, .graph_resync_binding_refs);

    var stmt_info_scope = profile.begin(.graph_resync_stmt_info);
    defer stmt_info_scope.end();
    module.prebuilt_stmt_info = null;
    if (ast.nodes.items.len == 0) return;
    const root = ast.nodes.items[ast.nodes.items.len - 1];
    if (root.tag != .program or root.data.list.len == 0) return;
    module.prebuilt_stmt_info = try stmt_info_mod.buildFromSemantic(
        arena_alloc,
        ast,
        semantic.symbols.items,
        semantic.scopes,
        semantic.references,
        &semantic.unresolved_references,
        false,
        module.memberAugmentGate(self.transform_options_base.minify_syntax),
    );
}

/// Retain the semantic graph after the narrow CJS Buffer fold. The caller gives
/// the complete pre-mutation node set removed by the fold. Any declaration,
/// scope owner, or graph-owned node in that set makes this transform ineligible
/// and returns false so the caller can reanalyze the already-mutated AST.
pub fn resyncAfterNodeBufferCapabilityFoldRetainingGraph(
    self: anytype,
    module: *Module,
    arena_alloc: std.mem.Allocator,
    removed_nodes: []const ast_mod.NodeIndex,
) !bool {
    const ast = &(module.ast orelse return error.MissingAst);
    const semantic = if (module.semantic) |*sem| sem else return error.MissingSemantic;
    if (removed_nodes.len == 0) return false;

    var removed = try std.DynamicBitSet.initEmpty(arena_alloc, ast.nodes.items.len);
    var reference_nodes = try std.DynamicBitSet.initEmpty(arena_alloc, ast.nodes.items.len);
    defer removed.deinit();
    defer reference_nodes.deinit();

    for (removed_nodes) |node_index| {
        if (node_index.isNone()) return false;
        const raw = @backingInt(node_index);
        if (raw >= ast.nodes.items.len or raw >= semantic.symbol_ids.len) return false;
        if (removed.isSet(raw)) return false;
        removed.set(raw);
        if (semantic.scope_owner_map.contains(raw) or
            semantic.class_self_symbol_map.contains(raw) or
            semantic.namespace_member_owners.contains(raw) or
            semantic.namespace_declaration_owners.contains(raw)) return false;
    }

    if (module.transform_cache) |cache| {
        for (cache.helper_ref_nodes) |raw| {
            if (raw < ast.nodes.items.len and removed.isSet(raw)) return false;
        }
        for (cache.explicit_global_ref_nodes) |raw| {
            if (raw < ast.nodes.items.len and removed.isSet(raw)) return false;
        }
        for (cache.preserved_class_name_nodes) |raw| {
            if (raw < ast.nodes.items.len and removed.isSet(raw)) return false;
        }
        for (cache.worklet_factory_local_bindings) |binding| {
            if (binding.node_index < ast.nodes.items.len and removed.isSet(binding.node_index)) return false;
        }
        for (cache.post_graph_output_bindings) |binding| {
            if (binding.node_index < ast.nodes.items.len and removed.isSet(binding.node_index)) return false;
        }
        var destructuring_temps = cache.destructuring_temp_bindings.keyIterator();
        while (destructuring_temps.next()) |raw| {
            if (raw.* < ast.nodes.items.len and removed.isSet(raw.*)) return false;
        }
    }
    if (module.tla_iife_stmt) |raw| {
        if (raw < ast.nodes.items.len and removed.isSet(raw)) return false;
    }
    if (module.tla_promise_reference) |promise_ref| {
        if (promise_ref.binding_node_index < ast.nodes.items.len and
            removed.isSet(promise_ref.binding_node_index)) return false;
    }

    var references_to_remove: std.ArrayListUnmanaged(ast_mod.NodeIndex) = .empty;
    defer references_to_remove.deinit(arena_alloc);
    for (semantic.references) |reference| {
        if (!reference.declaration_node_index.isNone()) {
            const declaration_raw = @backingInt(reference.declaration_node_index);
            if (declaration_raw < ast.nodes.items.len and removed.isSet(declaration_raw)) return false;
        }
        if (reference.node_index.isNone()) continue;
        const raw = @backingInt(reference.node_index);
        if (raw >= ast.nodes.items.len) return false;
        if (!removed.isSet(raw)) continue;
        const node_symbol = semantic.symbol_ids[raw] orelse return false;
        if (node_symbol != @backingInt(reference.symbol_id)) return false;
        if (reference_nodes.isSet(raw)) return false;
        reference_nodes.set(raw);
        try references_to_remove.append(arena_alloc, reference.node_index);
    }
    for (removed_nodes) |node_index| {
        const raw = @backingInt(node_index);
        if (semantic.symbol_ids[raw] != null and !reference_nodes.isSet(raw)) return false;
    }

    var editor = try semantic.beginEdit(arena_alloc, ast);
    defer editor.deinit();
    try editor.removeReferences(references_to_remove.items);
    semantic.applyEdit(try editor.finish());
    if (module.transform_cache) |*cache| cache.symbol_ids = semantic.symbol_ids;

    try resyncModuleGraphMetadataAfterAstMutation(self, module, arena_alloc);
    module.prebuilt_stmt_info = try stmt_info_mod.buildFromSemantic(
        arena_alloc,
        ast,
        semantic.symbols.items,
        semantic.scopes,
        semantic.references,
        &semantic.unresolved_references,
        false,
        module.memberAugmentGate(self.transform_options_base.minify_syntax),
    );
    return true;
}

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
    const previous_cjs_runtime_internal_symbols = module.cjs_runtime_internal_symbols;
    const previous_esm_runtime_internal_symbols = module.esm_runtime_internal_symbols;
    const previous_to_binary_runtime_symbol = module.to_binary_runtime_symbol;
    const previous_esm_runtime_factory_symbol = module.esm_runtime_factory_symbol;
    const previous_esm_interop_runtime_helper_symbols = module.esm_interop_runtime_helper_symbols;
    const previous_semantic = try refreshSemanticAndStmtInfoAfterAstMutation(self, module, arena_alloc);
    try refreshStableBindingRefsFromSemanticGraph(self, module, arena_alloc, .graph_resync_binding_refs);
    if (self.wrapper_symbols_registered) try self.registerWrapperSymbols();
    try captureRenamesAfterResync(
        self,
        module,
        arena_alloc,
        rename_table,
        previous_semantic,
        previous_cjs_runtime_internal_symbols,
        previous_esm_runtime_internal_symbols,
        previous_to_binary_runtime_symbol,
        previous_esm_runtime_factory_symbol,
        previous_esm_interop_runtime_helper_symbols,
    );
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
        if (module.semantic) |*sem| {
            binding_scanner_mod.markDefaultExportFacadesFromSemantic(
                module.export_bindings,
                sem.symbol_ids,
                sem.symbols.items,
            );
        }
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

    const previous_cjs_runtime_internal_symbols = module.cjs_runtime_internal_symbols;
    const previous_esm_runtime_internal_symbols = module.esm_runtime_internal_symbols;
    const previous_to_binary_runtime_symbol = module.to_binary_runtime_symbol;
    const previous_esm_runtime_factory_symbol = module.esm_runtime_factory_symbol;
    const previous_esm_interop_runtime_helper_symbols = module.esm_interop_runtime_helper_symbols;
    const previous_semantic = try refreshSemanticAndStmtInfoAfterAstMutation(self, module, arena_alloc);
    // The fresh analysis counts references in the current AST, which already
    // reflects prepass minify edits (inlined constants, folded dead branches).
    // Deltas recorded against the previous symbol table would subtract those
    // edits a second time and let the emitter drop live declarations.
    if (module.transform_cache) |*cache| cache.ref_deltas = &.{};
    try resyncModuleGraphMetadataAfterAstMutation(self, module, arena_alloc);
    // Reanalysis drops graph-only rows. Reattach exact wrapper/runtime IDs
    // before carrying any linker names into the new semantic snapshot. Before
    // finalize registers them there are none, and this runs on discovery
    // workers where the graph-wide registration races other modules (#5604).
    if (self.wrapper_symbols_registered) try self.registerWrapperSymbols();
    try captureRenamesAfterResync(
        self,
        module,
        arena_alloc,
        rename_table,
        previous_semantic,
        previous_cjs_runtime_internal_symbols,
        previous_esm_runtime_internal_symbols,
        previous_to_binary_runtime_symbol,
        previous_esm_runtime_factory_symbol,
        previous_esm_interop_runtime_helper_symbols,
    );
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
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(0));
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
    const module_index: bundler_symbol.ModuleIndex = @fromBackingInt(@intCast(0));
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

test "const materialization keeps surviving SymbolIds and removes exact references" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();
    const source = "const value=7; function shadow(value) { return value; } console.log(value, value, shadow(1));";

    var scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, source);
    scanner.is_module = true;
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.is_module = true;
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var value_symbol: ?u32 = null;
    var shadow_parameter_symbol: ?u32 = null;
    var value_binding_node: ast_mod.NodeIndex = .none;
    var shadow_parameter_node: ast_mod.NodeIndex = .none;
    for (analyzer.symbols.items, 0..) |symbol, symbol_index| {
        if (!std.mem.eql(u8, parser.ast.getText(symbol.name), "value")) continue;
        if (symbol.kind == .variable_const) value_symbol = @intCast(symbol_index);
        if (symbol.kind == .parameter) shadow_parameter_symbol = @intCast(symbol_index);
    }
    try std.testing.expect(value_symbol != null);
    try std.testing.expect(shadow_parameter_symbol != null);
    for (parser.ast.nodes.items, 0..) |node, node_index| {
        if (node.tag != .binding_identifier or node_index >= analyzer.symbol_ids.items.len) continue;
        const symbol_id = analyzer.symbol_ids.items[node_index] orelse continue;
        if (symbol_id == value_symbol.?) value_binding_node = @fromBackingInt(@intCast(node_index));
        if (symbol_id == shadow_parameter_symbol.?) shadow_parameter_node = @fromBackingInt(@intCast(node_index));
    }
    try std.testing.expect(!value_binding_node.isNone());
    try std.testing.expect(!shadow_parameter_node.isNone());

    var materialized_nodes: [2]ast_mod.NodeIndex = undefined;
    var materialized_count: usize = 0;
    for (analyzer.references.items) |reference| {
        if (@backingInt(reference.symbol_id) != value_symbol.? or reference.node_index.isNone()) continue;
        const node_index = @backingInt(reference.node_index);
        try std.testing.expectEqual(NodeTag.identifier_reference, parser.ast.nodes.items[node_index].tag);
        const span = try parser.ast.addString("7");
        parser.ast.nodes.items[node_index] = .{
            .tag = .numeric_literal,
            .span = span,
            .data = .{ .none = 0 },
        };
        try std.testing.expect(materialized_count < materialized_nodes.len);
        materialized_nodes[materialized_count] = reference.node_index;
        materialized_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), materialized_count);

    var module = Module.init(@fromBackingInt(@intCast(0)), "test.js");
    module.source = source;
    module.ast = parser.ast;
    module.parse_arena = &test_arena;
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
    module.transform_cache = .{
        .runtime_helpers = .{},
        .symbol_ids = module.semantic.?.symbol_ids,
    };
    const test_context = .{
        .allocator = allocator,
        .transform_options_base = .{ .minify_syntax = false },
    };
    try resyncAfterConstMaterializationRetainingGraph(
        &test_context,
        &module,
        allocator,
        materialized_nodes[0..materialized_count],
    );

    const semantic = &module.semantic.?;
    try std.testing.expectEqual(value_symbol.?, semantic.symbol_ids[@backingInt(value_binding_node)].?);
    try std.testing.expectEqual(
        shadow_parameter_symbol.?,
        semantic.symbol_ids[@backingInt(shadow_parameter_node)].?,
    );
    for (materialized_nodes[0..materialized_count]) |node_index| {
        const raw = @backingInt(node_index);
        try std.testing.expect(semantic.symbol_ids[raw] == null);
        try std.testing.expect(module.transform_cache.?.symbol_ids[raw] == null);
    }

    var value_reference_count: usize = 0;
    var shadow_parameter_reference_count: usize = 0;
    for (semantic.references) |reference| {
        if (@backingInt(reference.symbol_id) == value_symbol.?) value_reference_count += 1;
        if (@backingInt(reference.symbol_id) == shadow_parameter_symbol.?) shadow_parameter_reference_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), value_reference_count);
    try std.testing.expectEqual(@as(usize, 1), shadow_parameter_reference_count);
    try std.testing.expectEqual(@as(u32, 0), semantic.symbols.items[value_symbol.?].reference_count);
    try std.testing.expectEqual(@as(u32, 1), semantic.symbols.items[shadow_parameter_symbol.?].reference_count);

    const stmt_infos = module.prebuilt_stmt_info orelse return error.MissingStmtInfo;
    for (stmt_infos.stmts) |stmt| {
        for (stmt.referenced_symbols) |symbol_id| {
            try std.testing.expect(symbol_id != value_symbol.?);
        }
    }
}

test "direct Node Buffer capability fold retains SymbolIds and removes exact references" {
    var test_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_arena.deinit();
    const allocator = test_arena.allocator();
    const source =
        \\var buffer = require("buffer");
        \\var Buffer = buffer.Buffer;
        \\if (Buffer.from && Buffer.alloc && Buffer.allocUnsafe && Buffer.allocUnsafeSlow) module.exports = buffer;
        \\else exports.Buffer = SafeBuffer;
        \\function SafeBuffer() { return Buffer(1); }
        \\SafeBuffer.from = 1;
    ;

    var scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, source);
    scanner.is_module = false;
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".cjs");
    parser.is_module = false;
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = false;
    analyzer.is_strict_mode = false;
    analyzer.enable_stmt_info = true;
    try analyzer.analyze();

    var buffer_binding: ?ast_mod.NodeIndex = null;
    var buffer_symbol: ?u32 = null;
    var fallback_symbol: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or raw >= analyzer.symbol_ids.items.len) continue;
        const name = parser.ast.getText(node.span);
        if (std.mem.eql(u8, name, "Buffer")) {
            buffer_binding = @fromBackingInt(@intCast(raw));
            buffer_symbol = analyzer.symbol_ids.items[raw];
        } else if (std.mem.eql(u8, name, "SafeBuffer")) {
            fallback_symbol = analyzer.symbol_ids.items[raw];
        }
    }
    try std.testing.expect(buffer_binding != null);
    try std.testing.expect(buffer_symbol != null);
    try std.testing.expect(fallback_symbol != null);
    const buffer_reference_count_before = analyzer.symbols.items[buffer_symbol.?].reference_count;
    var buffer_refs_before: usize = 0;
    var fallback_refs_before: usize = 0;
    for (analyzer.references.items) |reference| {
        if (reference.node_index.isNone()) continue;
        if (@backingInt(reference.symbol_id) == buffer_symbol.?) buffer_refs_before += 1;
        if (@backingInt(reference.symbol_id) == fallback_symbol.?) fallback_refs_before += 1;
    }
    try std.testing.expect(buffer_refs_before >= 4);
    try std.testing.expect(fallback_refs_before > 0);

    var module = Module.init(@fromBackingInt(@intCast(0)), "test.cjs");
    module.source = source;
    module.ast = parser.ast;
    module.parse_arena = &test_arena;
    module.wrap_kind = .cjs;
    module.exports_kind = .commonjs;
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
    module.transform_cache = .{
        .runtime_helpers = .{},
        .symbol_ids = module.semantic.?.symbol_ids,
    };

    var removed_nodes: std.ArrayListUnmanaged(ast_mod.NodeIndex) = .empty;
    defer removed_nodes.deinit(allocator);
    try std.testing.expect(try cjs_patterns.foldNodeBufferCapabilityIfsRetainingGraph(
        allocator,
        &module.ast.?,
        &removed_nodes,
    ));
    try std.testing.expect(removed_nodes.items.len > 0);

    const test_context = .{
        .allocator = allocator,
        .defines = &[_]@import("../../parser/scan_results.zig").DefineEntry{},
        .wrapper_symbols_registered = false,
        .wrap_kinds_finalized = true,
        .transform_options_base = .{ .minify_syntax = false },
    };
    try std.testing.expect(try resyncAfterNodeBufferCapabilityFoldRetainingGraph(
        &test_context,
        &module,
        allocator,
        removed_nodes.items,
    ));

    const semantic = &module.semantic.?;
    const binding_raw = @backingInt(buffer_binding.?);
    try std.testing.expectEqual(buffer_symbol.?, semantic.symbol_ids[binding_raw].?);
    try std.testing.expectEqual(buffer_symbol.?, module.transform_cache.?.symbol_ids[binding_raw].?);
    var buffer_refs_after: usize = 0;
    var fallback_refs_after: usize = 0;
    for (semantic.references) |reference| {
        if (reference.node_index.isNone()) continue;
        if (@backingInt(reference.symbol_id) == buffer_symbol.?) buffer_refs_after += 1;
        if (@backingInt(reference.symbol_id) == fallback_symbol.?) fallback_refs_after += 1;
    }
    try std.testing.expectEqual(buffer_refs_before - 4, buffer_refs_after);
    try std.testing.expectEqual(@as(usize, 0), fallback_refs_after);
    try std.testing.expectEqual(
        buffer_reference_count_before - 4,
        semantic.symbols.items[buffer_symbol.?].reference_count,
    );
    for (removed_nodes.items) |node_index| {
        const raw = @backingInt(node_index);
        try std.testing.expect(semantic.symbol_ids[raw] == null);
        try std.testing.expect(module.transform_cache.?.symbol_ids[raw] == null);
    }
    try std.testing.expect(module.prebuilt_stmt_info != null);
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
