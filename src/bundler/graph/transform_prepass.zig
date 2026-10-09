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
const define_mod = @import("../../transformer/transformer/define.zig");
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
/// graph 단계 pre-pass 는 helper import 또는 최종 이름 결정 전에 등록해야 하는
/// graph-visible 전역을 만드는 모듈에 필요하다. 단순 ESM/TS-strip 모듈은 parser
/// metadata와 emit 단계의 legacy transformer/codegen 경로를 그대로 쓴다.
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

/// Local TypeScript import-equals aliases preserve module graph shape when
/// lowered to const bindings.
fn isSupportedLocalImportEquals(ast: *const ast_mod.Ast, node: ast_mod.Node) bool {
    if (node.tag != .ts_import_equals_declaration) return false;
    var value_idx = node.data.binary.right;
    while (!value_idx.isNone()) {
        if (@intFromEnum(value_idx) >= ast.nodes.items.len) return false;
        const value = ast.getNode(value_idx);
        switch (value.tag) {
            .identifier_reference => return true,
            .static_member_expression => {
                if (value.data.extra >= ast.extra_data.items.len) return false;
                value_idx = @enumFromInt(ast.extra_data.items[value.data.extra]);
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
    if (value_idx.isNone() or @intFromEnum(value_idx) >= ast.nodes.items.len) return false;
    const value = ast.getNode(value_idx);
    if (value.tag != .call_expression) return false;
    if (!ast.hasExtra(value.data.extra, 2)) return false;

    const callee_idx = ast.readExtraNode(value.data.extra, 0);
    if (callee_idx.isNone() or @intFromEnum(callee_idx) >= ast.nodes.items.len) return false;
    const callee = ast.getNode(callee_idx);
    const callee_name = ast.getText(callee.span);
    const arg_count = ast.readExtra(value.data.extra, 2);
    if (callee.tag != .identifier_reference or !std.mem.eql(u8, callee_name, "require")) return false;
    if (arg_count != 1) return false;

    const args_start = ast.readExtra(value.data.extra, 1);
    if (args_start >= ast.extra_data.items.len) return false;
    const arg_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);
    return !arg_idx.isNone() and @intFromEnum(arg_idx) < ast.nodes.items.len and
        ast.getNode(arg_idx).tag == .string_literal;
}

/// Plain top-level `export * from "specifier"` keeps the same re-export
/// loader record through lowering. Namespace re-exports and import attributes
/// stay on the full graph-resync path.
fn isSupportedPlainExportAll(ast: *const ast_mod.Ast, node_idx: ast_mod.NodeIndex) bool {
    if (node_idx.isNone() or @intFromEnum(node_idx) >= ast.nodes.items.len) return false;
    const node = ast.getNode(node_idx);
    if (node.tag != .export_all_declaration) return false;
    var top_level = ast_walk.topLevelStatementMask(ast) catch return false;
    defer top_level.deinit();
    if (!top_level.isSet(@intFromEnum(node_idx))) return false;

    const export_all = module_parser.readExportAllExtras(ast, node.data.extra);
    if (!export_all.exported_name.isNone() or export_all.attrs_len != 0) return false;
    if (export_all.source.isNone() or @intFromEnum(export_all.source) >= ast.nodes.items.len) return false;
    return ast.getNode(export_all.source).tag == .string_literal;
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

/// Static named re-exports preserve the same loader record if every exported
/// name is an identifier and the declaration has no attributes. Inline
/// type-only specifiers are allowed because their re-export still evaluates
/// the source module for side effects after TypeScript erasure.
fn isSupportedStaticNamedReExport(ast: *const ast_mod.Ast, export_decl: module_parser.ExportNamedExtras) bool {
    if (!export_decl.decl.isNone() or export_decl.source.isNone() or export_decl.attrs_len != 0) return false;
    if (@intFromEnum(export_decl.source) >= ast.nodes.items.len or
        ast.getNode(export_decl.source).tag != .string_literal) return false;
    if (export_decl.specs_start > ast.extra_data.items.len or
        export_decl.specs_len > ast.extra_data.items.len - export_decl.specs_start) return false;

    for (ast.extra_data.items[export_decl.specs_start .. export_decl.specs_start + export_decl.specs_len]) |raw_spec_idx| {
        if (raw_spec_idx >= ast.nodes.items.len) return false;
        const specifier = ast.nodes.items[raw_spec_idx];
        if (specifier.tag != .export_specifier) return false;
        const local_idx = specifier.data.binary.left;
        if (local_idx.isNone() or @intFromEnum(local_idx) >= ast.nodes.items.len or
            ast.getNode(local_idx).tag != .identifier_reference) return false;

        const exported_idx = specifier.data.binary.right;
        if (!exported_idx.isNone() and
            (@intFromEnum(exported_idx) >= ast.nodes.items.len or
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

fn hasOnlyArrayLiteralSpreadOperands(ast: *const ast_mod.Ast, node: ast_mod.Node) bool {
    const extras = ast.extra_data.items;
    const start: u32, const len: u32 = switch (node.tag) {
        .array_expression => .{ node.data.list.start, node.data.list.len },
        .call_expression => blk: {
            const extra = node.data.extra;
            if (extra > extras.len or extras.len - extra <= 3) return false;
            const callee: ast_mod.NodeIndex = @enumFromInt(extras[extra]);
            if (callee.isNone() or @intFromEnum(callee) >= ast.nodes.items.len or
                ast.nodes.items[@intFromEnum(callee)].tag != .identifier_reference) return false;
            break :blk .{ extras[extra + 1], extras[extra + 2] };
        },
        else => return false,
    };
    if (start > extras.len or len > extras.len - start) return false;

    for (extras[start .. start + len]) |raw_idx| {
        if (raw_idx >= ast.nodes.items.len) return false;
        const element = ast.nodes.items[raw_idx];
        if (element.tag != .spread_element) continue;
        const operand = element.data.unary.operand;
        if (operand.isNone() or @intFromEnum(operand) >= ast.nodes.items.len) return false;
        const operand_node = ast.nodes.items[@intFromEnum(operand)];
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
            node.data.binary.flags == @intFromEnum(token_mod.Kind.star2);
        const is_exponentiation_assignment = node.tag == .assignment_expression and
            node.data.binary.flags == @intFromEnum(token_mod.Kind.star2_eq);
        if (is_binary_exponentiation or is_exponentiation_assignment) return true;
    }
    return false;
}

// Accessor `super` can add a runtime helper module during lowering. Keep those
// owners on graph resync until helper imports can be edited with the graph.
// Scan nested nodes conservatively.
fn methodHasSuperExpression(ast: *const ast_mod.Ast, method: ast_mod.Node) bool {
    if (method.tag != .method_definition) return true;
    const extra = method.data.extra;
    if (extra > ast.extra_data.items.len or
        ast.extra_data.items.len - extra <= ast_mod.MethodExtra.body) return true;
    const roots = [_]ast_mod.NodeIndex{
        @enumFromInt(ast.extra_data.items[extra + ast_mod.MethodExtra.params]),
        @enumFromInt(ast.extra_data.items[extra + ast_mod.MethodExtra.body]),
    };
    for (roots) |root| {
        if (root.isNone() or @intFromEnum(root) >= ast.nodes.items.len) return true;
        const descendants = ast_walk.collectReachableNodeIndicesFrom(ast.allocator, ast, root) catch return true;
        defer ast.allocator.free(descendants);
        for (descendants) |raw_idx| {
            if (ast.nodes.items[raw_idx].tag == .super_expression) return true;
        }
    }
    return false;
}

fn hasValidSourceSymbol(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
    expected_tag: NodeTag,
) bool {
    if (node_idx.isNone() or @intFromEnum(node_idx) >= ast.nodes.items.len or
        ast.getNode(node_idx).tag != expected_tag) return false;
    const raw_idx = @intFromEnum(node_idx);
    if (raw_idx >= semantic.symbol_ids.len) return false;
    const symbol_raw = semantic.symbol_ids[raw_idx] orelse return false;
    if (symbol_raw >= semantic.symbols.items.len) return false;
    const scope_id = semantic.symbols.items[symbol_raw].scope_id;
    return !scope_id.isNone() and @intFromEnum(scope_id) < semantic.scopes.len;
}

fn isBoundSourceIdentifierReference(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
) bool {
    return hasValidSourceSymbol(ast, semantic, node_idx, .identifier_reference);
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

/// A nested ordinary source-call chain is captured into an exact tracked temp
/// by optional-chain lowering. Keep it rooted at a bound source identifier and
/// exclude optional calls and other callee shapes from this chain.
fn isRetainableOptionalReceiverCallCallee(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    callee_idx: ast_mod.NodeIndex,
) bool {
    var current = callee_idx;
    while (true) {
        if (current.isNone() or @intFromEnum(current) >= ast.nodes.items.len) return false;
        const callee = ast.getNode(current);
        if (callee.tag == .identifier_reference)
            return isBoundSourceIdentifierReference(ast, semantic, current);
        if (callee.tag != .call_expression) return false;
        const extra = callee.data.extra;
        if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 3) return false;
        if ((ast.extra_data.items[extra + 3] & ast_mod.CallFlags.optional_chain) != 0) return false;
        current = @enumFromInt(ast.extra_data.items[extra]);
    }
}

/// A direct or nested ordinary source call is evaluated once into a tracked
/// temp by optional lowering. Computed optional member segments are traversed
/// only as part of this chain; computed non-optional tails remain outside it.
fn isRetainableOptionalMemberReceiver(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    receiver_idx: ast_mod.NodeIndex,
) bool {
    if (ast.has_jsx) return false;
    var current = receiver_idx;
    while (true) {
        if (current.isNone() or @intFromEnum(current) >= ast.nodes.items.len) return false;
        const receiver = ast.getNode(current);
        switch (receiver.tag) {
            .identifier_reference => return isBoundSourceIdentifierReference(ast, semantic, current),
            .static_member_expression, .computed_member_expression => {
                const extra = receiver.data.extra;
                if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 2)
                    return false;
                if ((ast.extra_data.items[extra + 2] & ast_mod.MemberFlags.optional_chain) == 0)
                    return false;
                current = @enumFromInt(ast.extra_data.items[extra]);
            },
            .call_expression => {
                const extra = receiver.data.extra;
                if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 3)
                    return false;
                if ((ast.extra_data.items[extra + 3] & ast_mod.CallFlags.optional_chain) != 0)
                    return isRetainableOptionalCall(ast, semantic, current);
                const callee: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra]);
                return isRetainableOptionalReceiverCallCallee(ast, semantic, callee);
            },
            else => return false,
        }
    }
}

fn isRetainableOptionalMemberAccess(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
) bool {
    if (node_idx.isNone() or @intFromEnum(node_idx) >= ast.nodes.items.len) return false;
    const node = ast.getNode(node_idx);
    if (node.tag != .static_member_expression and node.tag != .computed_member_expression) return false;
    const extra = node.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 2) return false;
    if ((ast.extra_data.items[extra + 2] & ast_mod.MemberFlags.optional_chain) == 0) return false;
    const receiver: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra]);
    return isRetainableOptionalMemberReceiver(ast, semantic, receiver);
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
        if (current.isNone() or @intFromEnum(current) >= ast.nodes.items.len) return false;
        const node = ast.getNode(current);
        switch (node.tag) {
            .static_member_expression, .computed_member_expression => {
                const extra = node.data.extra;
                if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 2)
                    return false;
                const receiver: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra]);
                const optional = (ast.extra_data.items[extra + 2] & ast_mod.MemberFlags.optional_chain) != 0;
                if (optional) return isRetainableOptionalMemberReceiver(ast, semantic, receiver);
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
                current = @enumFromInt(ast.extra_data.items[extra]);
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
    if (node_idx.isNone() or @intFromEnum(node_idx) >= ast.nodes.items.len) return false;
    const node = ast.getNode(node_idx);
    if (node.tag != .static_member_expression and node.tag != .computed_member_expression) return false;
    const extra = node.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 2) return false;
    const receiver: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra]);
    if ((ast.extra_data.items[extra + 2] & ast_mod.MemberFlags.optional_chain) != 0)
        return isRetainableOptionalMemberReceiver(ast, semantic, receiver);
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
        if (current.isNone() or @intFromEnum(current) >= ast.nodes.items.len) return false;
        const call = ast.getNode(current);
        if (call.tag != .call_expression) return false;
        const extra = call.data.extra;
        if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 3) return false;
        const callee: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra]);
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
    if (node_idx.isNone() or @intFromEnum(node_idx) >= ast.nodes.items.len) return false;
    const call = ast.getNode(node_idx);
    if (call.tag != .call_expression) return false;
    const extra = call.data.extra;
    if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 3) return false;
    const optional_call = (ast.extra_data.items[extra + 3] & ast_mod.CallFlags.optional_chain) != 0;
    const callee: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra]);
    if (callee.isNone() or @intFromEnum(callee) >= ast.nodes.items.len) return false;
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
            return isRetainableOptionalReceiverCallCallee(ast, semantic, callee) or
                isRetainableOptionalCallResultTail(ast, semantic, callee);
        }
        // `method?.()()` keeps the optional short-circuit around the complete
        // ordinary call tail and retains the source callee identity.
        return isRetainableOptionalCallResultTail(ast, semantic, callee);
    }
    if (member.tag != .static_member_expression and member.tag != .computed_member_expression) return false;
    const member_extra = member.data.extra;
    if (member_extra > ast.extra_data.items.len or ast.extra_data.items.len - member_extra <= 2) return false;
    if ((ast.extra_data.items[member_extra + 2] & ast_mod.MemberFlags.optional_chain) != 0) {
        return isRetainableOptionalMemberAccess(ast, semantic, callee);
    }
    const receiver: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[member_extra]);
    if (!optional_call) return isRetainableOptionalMemberChainTail(ast, semantic, callee);
    return isRetainableOptionalMemberReceiver(ast, semantic, receiver);
}

/// Compound/logical assignment lowering already records member receiver/key
/// temps in the edited graph. Admit ordinary member targets when they contain
/// no super/private access that takes a separate lowering path.
fn isRetainableAssignmentTarget(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node_idx: ast_mod.NodeIndex,
) bool {
    if (node_idx.isNone() or @intFromEnum(node_idx) >= ast.nodes.items.len) return false;
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
        if (current.isNone() or @intFromEnum(current) >= ast.nodes.items.len) return false;
        const raw = @intFromEnum(current);
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
    if (value_idx.isNone() or @intFromEnum(value_idx) >= ast.nodes.items.len) return false;
    const value = ast.getNode(value_idx);
    if (value.tag == .binary_expression) {
        const operator: token_mod.Kind = @enumFromInt(value.data.binary.flags);
        return isSafeConstructorBinaryOperator(operator) and
            isSafeConstructorValue(ast, semantic, value.data.binary.left) and
            isSafeConstructorValue(ast, semantic, value.data.binary.right);
    }
    if (value.tag == .unary_expression) {
        const extras = ast.extra_data.items;
        const extra = value.data.extra;
        if (extra > extras.len or extras.len - extra < 2) return false;
        const operator: token_mod.Kind = @enumFromInt(@as(u8, @truncate(extras[extra + 1])));
        const operand_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra]);
        return isSafeConstructorUnaryOperator(operator) and
            isSafeConstructorValue(ast, semantic, operand_idx);
    }
    if (value.tag == .logical_expression) {
        const operator: token_mod.Kind = @enumFromInt(value.data.binary.flags);
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

/// A member receiver may be an exact bound identifier or a non-optional
/// static/computed member chain rooted at one. Computed keys must be safe
/// values or calls; the expression worklist validates the calls separately.
/// The node-count bound also rejects malformed cycles.
fn isRetainableBoundStaticFieldMemberReceiver(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    receiver_idx: ast_mod.NodeIndex,
) bool {
    if (receiver_idx.isNone() or @intFromEnum(receiver_idx) >= ast.nodes.items.len) return false;
    const extras = ast.extra_data.items;
    var current_idx = receiver_idx;
    var remaining_nodes = ast.nodes.items.len;
    while (remaining_nodes > 0) : (remaining_nodes -= 1) {
        if (current_idx.isNone() or @intFromEnum(current_idx) >= ast.nodes.items.len) return false;
        const current = ast.getNode(current_idx);
        if (current.tag == .identifier_reference)
            return isBoundSourceIdentifierReference(ast, semantic, current_idx);
        if (current.tag != .static_member_expression and current.tag != .computed_member_expression) return false;

        const extra = current.data.extra;
        if (extra > extras.len or extras.len - extra < 3 or extras[extra + 2] != 0) return false;
        const object_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra]);
        const property_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra + 1]);
        if (property_idx.isNone() or @intFromEnum(property_idx) >= ast.nodes.items.len) return false;
        const property = ast.getNode(property_idx);
        switch (current.tag) {
            .static_member_expression => if (property.tag != .identifier_reference) return false,
            .computed_member_expression => if (!isSafeConstructorValue(ast, semantic, property_idx) and
                property.tag != .call_expression) return false,
            else => return false,
        }
        current_idx = object_idx;
    }
    return false;
}

/// A member access is safe to retain when its receiver chain is rooted at an
/// exact source binding and every segment is non-optional. Computed keys must
/// be safe values or calls; the shared iterative expression walk validates all
/// calls in receiver segments and the final key.
fn isBoundStaticFieldMemberAccessShape(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    member_idx: ast_mod.NodeIndex,
) bool {
    if (member_idx.isNone() or @intFromEnum(member_idx) >= ast.nodes.items.len) return false;
    const member = ast.getNode(member_idx);
    if (member.tag != .static_member_expression and member.tag != .computed_member_expression) return false;
    const extras = ast.extra_data.items;
    const extra = member.data.extra;
    if (extra > extras.len or extras.len - extra < 3 or extras[extra + 2] != 0) return false;
    const receiver_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra]);
    const property_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra + 1]);
    if (!isRetainableBoundStaticFieldMemberReceiver(ast, semantic, receiver_idx) or
        property_idx.isNone() or @intFromEnum(property_idx) >= ast.nodes.items.len) return false;
    return switch (member.tag) {
        .static_member_expression => ast.getNode(property_idx).tag == .identifier_reference,
        .computed_member_expression => isSafeConstructorValue(ast, semantic, property_idx) or
            ast.getNode(property_idx).tag == .call_expression,
        else => false,
    };
}

/// Optional member chains rooted directly at an exact source binding can stay
/// on the edited graph when their segments are dot reads or optional computed
/// reads with safe values or exact-bound call keys. The shared iterative call
/// validator checks call-key subtrees. Keep other calls and non-source roots
/// on reanalysis.
fn isRetainableBoundStaticFieldOptionalMemberChain(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    member_idx: ast_mod.NodeIndex,
) bool {
    const extras = ast.extra_data.items;
    var current_idx = member_idx;
    var saw_optional = false;
    var remaining_nodes = ast.nodes.items.len;
    while (remaining_nodes > 0) : (remaining_nodes -= 1) {
        if (current_idx.isNone() or @intFromEnum(current_idx) >= ast.nodes.items.len) return false;
        const member = ast.getNode(current_idx);
        if (member.tag == .identifier_reference)
            return saw_optional and isBoundSourceIdentifierReference(ast, semantic, current_idx);
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
        const receiver_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra]);
        const property_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra + 1]);
        if (receiver_idx.isNone() or @intFromEnum(receiver_idx) >= ast.nodes.items.len or
            property_idx.isNone() or @intFromEnum(property_idx) >= ast.nodes.items.len)
        {
            return false;
        }
        const property = ast.getNode(property_idx);
        if (member.tag == .static_member_expression) {
            if (property.tag != .identifier_reference) return false;
        } else if (!isSafeConstructorValue(ast, semantic, property_idx)) {
            if (property.tag != .call_expression or
                !isRetainableBoundStaticFieldExpression(allocator, ast, semantic, property_idx)) return false;
        }
        current_idx = receiver_idx;
    }
    return false;
}

fn enqueueBoundStaticFieldMemberKeyCalls(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    member_idx: ast_mod.NodeIndex,
    pending: *std.ArrayList(ast_mod.NodeIndex),
) bool {
    const extras = ast.extra_data.items;
    var current_idx = member_idx;
    var remaining_nodes = ast.nodes.items.len;
    while (remaining_nodes > 0) : (remaining_nodes -= 1) {
        if (current_idx.isNone() or @intFromEnum(current_idx) >= ast.nodes.items.len) return false;
        const member = ast.getNode(current_idx);
        if (member.tag != .static_member_expression and member.tag != .computed_member_expression) return false;
        const extra = member.data.extra;
        if (extra > extras.len or extras.len - extra < 3 or extras[extra + 2] != 0) return false;
        const object_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra]);
        const property_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra + 1]);
        if (property_idx.isNone() or @intFromEnum(property_idx) >= ast.nodes.items.len) return false;
        if (member.tag == .computed_member_expression and
            !isSafeConstructorValue(ast, semantic, property_idx))
        {
            if (ast.getNode(property_idx).tag != .call_expression) return false;
            pending.append(allocator, property_idx) catch return false;
        }
        if (object_idx.isNone() or @intFromEnum(object_idx) >= ast.nodes.items.len) return false;
        if (ast.getNode(object_idx).tag == .identifier_reference)
            return isBoundSourceIdentifierReference(ast, semantic, object_idx);
        current_idx = object_idx;
    }
    return false;
}

/// Safe static-field calls and computed keys are validated together on one
/// iterative worklist. This keeps deeply nested calls out of recursive helper
/// chains, rejects repeated nodes/cycles, and leaves the original AST intact so
/// evaluation order and a computed member callee's receiver (`this`) survive.
/// Optional or unresolved callees and effectful non-call arguments stay on
/// semantic reanalysis.
fn isRetainableBoundStaticFieldExpression(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    expression_idx: ast_mod.NodeIndex,
) bool {
    if (expression_idx.isNone() or @intFromEnum(expression_idx) >= ast.nodes.items.len) return false;
    const extras = ast.extra_data.items;
    var pending: std.ArrayList(ast_mod.NodeIndex) = .empty;
    defer pending.deinit(allocator);
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(allocator);
    pending.append(allocator, expression_idx) catch return false;
    var remaining_nodes = ast.nodes.items.len;

    while (pending.pop()) |current_idx| {
        if (remaining_nodes == 0 or current_idx.isNone() or
            @intFromEnum(current_idx) >= ast.nodes.items.len) return false;
        remaining_nodes -= 1;
        const raw_current = @intFromEnum(current_idx);
        if (visited.contains(raw_current)) return false;
        visited.put(allocator, raw_current, {}) catch return false;

        if (isSafeConstructorValue(ast, semantic, current_idx)) continue;
        const call = ast.getNode(current_idx);
        switch (call.tag) {
            .call_expression => {
                const extra = call.data.extra;
                if (extra > extras.len or extras.len - extra < 4) return false;
                if ((extras[extra + 3] & ast_mod.CallFlags.optional_chain) != 0) return false;

                const callee_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra]);
                if (callee_idx.isNone() or @intFromEnum(callee_idx) >= ast.nodes.items.len) return false;
                const callee = ast.getNode(callee_idx);
                switch (callee.tag) {
                    .identifier_reference => {
                        if (!isBoundSourceIdentifierReference(ast, semantic, callee_idx)) return false;
                    },
                    .static_member_expression, .computed_member_expression => {
                        if (!isBoundStaticFieldMemberAccessShape(ast, semantic, callee_idx) or
                            !enqueueBoundStaticFieldMemberKeyCalls(allocator, ast, semantic, callee_idx, &pending)) return false;
                    },
                    else => return false,
                }
                const args_start = extras[extra + 1];
                const args_len = extras[extra + 2];
                if (args_start > extras.len or args_len > extras.len - args_start) return false;
                for (extras[args_start .. args_start + args_len]) |raw_arg| {
                    if (raw_arg >= ast.nodes.items.len) return false;
                    const argument_idx: ast_mod.NodeIndex = @enumFromInt(raw_arg);
                    if (isSafeConstructorValue(ast, semantic, argument_idx)) continue;
                    if (ast.getNode(argument_idx).tag != .call_expression) return false;
                    pending.append(allocator, argument_idx) catch return false;
                }
            },
            .static_member_expression, .computed_member_expression => {
                if (!isBoundStaticFieldMemberAccessShape(ast, semantic, current_idx) or
                    !enqueueBoundStaticFieldMemberKeyCalls(allocator, ast, semantic, current_idx, &pending)) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn isRetainableBoundStaticFieldMemberAccess(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    member_idx: ast_mod.NodeIndex,
) bool {
    return isRetainableBoundStaticFieldExpression(allocator, ast, semantic, member_idx);
}

fn isRetainableBoundStaticFieldInitializerMemberAccess(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    member_idx: ast_mod.NodeIndex,
) bool {
    return isRetainableBoundStaticFieldOptionalMemberChain(allocator, ast, semantic, member_idx) or
        isRetainableBoundStaticFieldMemberAccess(allocator, ast, semantic, member_idx);
}

fn isRetainableBoundStaticFieldCall(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    call_idx: ast_mod.NodeIndex,
) bool {
    if (call_idx.isNone() or @intFromEnum(call_idx) >= ast.nodes.items.len or
        ast.getNode(call_idx).tag != .call_expression) return false;
    return isRetainableBoundStaticFieldExpression(allocator, ast, semantic, call_idx);
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
        const binding_idx: ast_mod.NodeIndex = @enumFromInt(extras[declarator_extra]);
        const type_annotation_idx: ast_mod.NodeIndex = @enumFromInt(extras[declarator_extra + 1]);
        const initializer_idx: ast_mod.NodeIndex = @enumFromInt(extras[declarator_extra + 2]);
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
    if (head_idx.isNone() or @intFromEnum(head_idx) >= ast.nodes.items.len) return false;
    const head = ast.getNode(head_idx);
    return switch (head.tag) {
        .variable_declaration => isSafeConstructorVarDeclaration(ast, semantic, head),
        .assignment_target_identifier => isBoundSourceIdentifierAssignmentTarget(ast, semantic, head_idx),
        else => false,
    };
}

fn isSafeConstructorLocalAssignment(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    assignment: ast_mod.Node,
) bool {
    if (assignment.tag != .assignment_expression) return false;
    const operator: token_mod.Kind = @enumFromInt(assignment.data.binary.flags);
    if (operator != .eq and !isSafeConstructorNativeCompoundAssignmentOperator(operator)) return false;
    const target_idx = assignment.data.binary.left;
    if (target_idx.isNone() or @intFromEnum(target_idx) >= ast.nodes.items.len or
        !isBoundSourceIdentifierAssignmentTarget(ast, semantic, target_idx)) return false;
    return isSafeConstructorValue(ast, semantic, assignment.data.binary.right);
}

fn isSafeConstructorThisPropertyTarget(ast: *const ast_mod.Ast, target_idx: ast_mod.NodeIndex) bool {
    if (target_idx.isNone() or @intFromEnum(target_idx) >= ast.nodes.items.len) return false;
    const target = ast.getNode(target_idx);
    if (target.tag != .static_member_expression) return false;
    const extras = ast.extra_data.items;
    const member_extra = target.data.extra;
    if (member_extra > extras.len or extras.len - member_extra < 3 or extras[member_extra + 2] != 0)
        return false;

    const receiver_idx: ast_mod.NodeIndex = @enumFromInt(extras[member_extra]);
    const property_idx: ast_mod.NodeIndex = @enumFromInt(extras[member_extra + 1]);
    if (receiver_idx.isNone() or @intFromEnum(receiver_idx) >= ast.nodes.items.len or
        ast.getNode(receiver_idx).tag != .this_expression or
        property_idx.isNone() or @intFromEnum(property_idx) >= ast.nodes.items.len or
        ast.getNode(property_idx).tag != .identifier_reference) return false;
    return std.mem.indexOfScalar(u8, ast.getText(ast.getNode(property_idx).span), '\\') == null;
}

fn isSafeConstructorThisPropertyAssignment(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    assignment: ast_mod.Node,
) bool {
    if (assignment.tag != .assignment_expression) return false;
    const operator: token_mod.Kind = @enumFromInt(assignment.data.binary.flags);
    if (!isSafeConstructorNativeCompoundAssignmentOperator(operator) or
        !isSafeConstructorThisPropertyTarget(ast, assignment.data.binary.left)) return false;
    return isSafeConstructorValue(ast, semantic, assignment.data.binary.right);
}

fn isSafeConstructorThisPropertyUpdate(ast: *const ast_mod.Ast, update: ast_mod.Node) bool {
    if (update.tag != .update_expression) return false;
    const extras = ast.extra_data.items;
    const extra = update.data.extra;
    if (extra > extras.len or extras.len - extra < 2) return false;
    const operator: token_mod.Kind = @enumFromInt(@as(u8, @truncate(extras[extra + 1])));
    if (operator != .plus2 and operator != .minus2) return false;
    const target_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra]);
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
    const operator: token_mod.Kind = @enumFromInt(@as(u8, @truncate(extras[extra + 1])));
    if (operator != .plus2 and operator != .minus2) return false;
    const target_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra]);
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
            const binding: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra]);
            if (binding.isNone() or @intFromEnum(binding) >= semantic.symbol_ids.len) return true;
            const binding_symbol = semantic.symbol_ids[@intFromEnum(binding)] orelse return true;
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
    const symbol_raw = semantic.symbol_ids[@intFromEnum(binding_idx)] orelse return false;
    var declaration_found = false;
    for (semantic.references) |reference| {
        if (@intFromEnum(reference.symbol_id) != symbol_raw) continue;
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
        const binding: ast_mod.NodeIndex = @enumFromInt(extras[declarator_extra]);
        const type_annotation: ast_mod.NodeIndex = @enumFromInt(extras[declarator_extra + 1]);
        const initializer: ast_mod.NodeIndex = @enumFromInt(extras[declarator_extra + 2]);
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
    if (expression_idx.isNone() or @intFromEnum(expression_idx) >= ast.nodes.items.len) return false;
    const assignment = ast.getNode(expression_idx);
    if (assignment.tag == .update_expression) {
        return isSafeConstructorLocalUpdate(ast, semantic, assignment) or
            isSafeConstructorThisPropertyUpdate(ast, assignment);
    }
    if (assignment.tag != .assignment_expression) return false;
    if (assignment.data.binary.flags != @intFromEnum(token_mod.Kind.eq)) {
        return isSafeConstructorLocalAssignment(ast, semantic, assignment) or
            isSafeConstructorThisPropertyAssignment(ast, semantic, assignment);
    }

    const target_idx = assignment.data.binary.left;
    const value_idx = assignment.data.binary.right;
    if (target_idx.isNone() or @intFromEnum(target_idx) >= ast.nodes.items.len or
        value_idx.isNone() or @intFromEnum(value_idx) >= ast.nodes.items.len) return false;
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
    if (case_idx.isNone() or @intFromEnum(case_idx) >= ast.nodes.items.len) return false;
    const switch_case = ast.getNode(case_idx);
    if (switch_case.tag != .switch_case) return false;
    const extras = ast.extra_data.items;
    const extra = switch_case.data.extra;
    if (extra > extras.len or extras.len - extra < 3) return false;
    const test_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra]);
    const statements_start = extras[extra + 1];
    const statements_len = extras[extra + 2];
    if ((!test_idx.isNone() and !isSafeConstructorValue(ast, semantic, test_idx)) or
        statements_start > extras.len or statements_len > extras.len - statements_start) return false;
    for (extras[statements_start .. statements_start + statements_len]) |raw_statement_idx| {
        if (raw_statement_idx >= ast.nodes.items.len or
            !isSafeConstructorBodyStatement(ast, semantic, @enumFromInt(raw_statement_idx))) return false;
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
    const initializer_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra]);
    const test_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra + 1]);
    const update_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra + 2]);
    const body_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra + 3]);
    if (initializer_idx.isNone() or @intFromEnum(initializer_idx) >= ast.nodes.items.len or
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
    if (catch_idx.isNone() or @intFromEnum(catch_idx) >= ast.nodes.items.len) return false;
    const catch_clause = ast.getNode(catch_idx);
    if (catch_clause.tag != .catch_clause) return false;
    const parameter_idx = catch_clause.data.binary.left;
    if (!parameter_idx.isNone() and !isBoundSourceIdentifierBinding(ast, semantic, parameter_idx)) return false;
    const body_idx = catch_clause.data.binary.right;
    return !body_idx.isNone() and @intFromEnum(body_idx) < ast.nodes.items.len and
        ast.getNode(body_idx).tag == .block_statement and
        isSafeConstructorBodyStatement(ast, semantic, body_idx);
}

fn isSafeConstructorLabelIdentifier(ast: *const ast_mod.Ast, label_idx: ast_mod.NodeIndex) bool {
    if (label_idx.isNone() or @intFromEnum(label_idx) >= ast.nodes.items.len) return false;
    const label = ast.getNode(label_idx);
    return label.tag == .identifier_reference and
        std.mem.indexOfScalar(u8, ast.getText(label.span), '\\') == null;
}

fn isSafeConstructorBodyStatement(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    statement_idx: ast_mod.NodeIndex,
) bool {
    if (statement_idx.isNone() or @intFromEnum(statement_idx) >= ast.nodes.items.len) return false;
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
                    !isSafeConstructorBodyStatement(ast, semantic, @enumFromInt(raw_statement_idx))) return false;
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
            const discriminant_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra]);
            const cases_start = extras[extra + 1];
            const cases_len = extras[extra + 2];
            if (!isSafeConstructorValue(ast, semantic, discriminant_idx) or
                cases_start > extras.len or cases_len > extras.len - cases_start) return false;
            for (extras[cases_start .. cases_start + cases_len]) |raw_case_idx| {
                if (raw_case_idx >= ast.nodes.items.len or
                    !isSafeConstructorSwitchCase(ast, semantic, @enumFromInt(raw_case_idx))) return false;
            }
            return true;
        },
        .try_statement => {
            const clauses = statement.data.ternary;
            if ((clauses.b.isNone() and clauses.c.isNone()) or clauses.a.isNone() or
                @intFromEnum(clauses.a) >= ast.nodes.items.len or
                ast.getNode(clauses.a).tag != .block_statement) return false;
            if (!clauses.c.isNone() and
                (@intFromEnum(clauses.c) >= ast.nodes.items.len or ast.getNode(clauses.c).tag != .block_statement))
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
            const initializer_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra]);
            const test_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra + 1]);
            const update_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra + 2]);
            const body_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra + 3]);
            if (!initializer_idx.isNone() and @intFromEnum(initializer_idx) < ast.nodes.items.len and
                ast.getNode(initializer_idx).tag == .variable_declaration and
                ast.variableDeclarationKind(ast.getNode(initializer_idx)).isLexical())
            {
                return isSafeRetainedLexicalForStatement(ast, semantic, statement);
            }
            const safe_initializer = initializer_idx.isNone() or
                (if (@intFromEnum(initializer_idx) < ast.nodes.items.len and
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
    const reference_symbol = semantic.symbol_ids[@intFromEnum(reference_idx)] orelse return false;
    for (ast.extra_data.items[params.start .. params.start + parameter_index]) |raw_parameter_idx| {
        if (raw_parameter_idx >= ast.nodes.items.len) return false;
        const parameter_idx: ast_mod.NodeIndex = @enumFromInt(raw_parameter_idx);
        const parameter = ast.getNode(parameter_idx);
        const binding_idx = switch (parameter.tag) {
            .binding_identifier => parameter_idx,
            .assignment_pattern => parameter.data.binary.left,
            else => return false,
        };
        if (!hasValidSourceSymbol(ast, semantic, binding_idx, .binding_identifier)) return false;
        if (semantic.symbol_ids[@intFromEnum(binding_idx)] == reference_symbol) return true;
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
    if (value_idx.isNone() or @intFromEnum(value_idx) >= ast.nodes.items.len) return false;
    const value = ast.getNode(value_idx);
    if (value.tag == .binary_expression) {
        const operator: token_mod.Kind = @enumFromInt(value.data.binary.flags);
        return isSafeConstructorBinaryOperator(operator) and
            isSafeConstructorParameterDefaultValue(ast, semantic, value.data.binary.left, params, parameter_index) and
            isSafeConstructorParameterDefaultValue(ast, semantic, value.data.binary.right, params, parameter_index);
    }
    if (value.tag == .unary_expression) {
        const extras = ast.extra_data.items;
        const extra = value.data.extra;
        if (extra > extras.len or extras.len - extra < 2) return false;
        const operator: token_mod.Kind = @enumFromInt(@as(u8, @truncate(extras[extra + 1])));
        const operand_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra]);
        return isSafeConstructorUnaryOperator(operator) and
            isSafeConstructorParameterDefaultValue(ast, semantic, operand_idx, params, parameter_index);
    }
    if (value.tag == .logical_expression) {
        const operator: token_mod.Kind = @enumFromInt(value.data.binary.flags);
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
    if (parameter_idx.isNone() or @intFromEnum(parameter_idx) >= ast.nodes.items.len) return false;
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
        default_idx.isNone() or @intFromEnum(default_idx) >= ast.nodes.items.len) return false;
    return isSafeConstructorParameterDefaultValue(ast, semantic, default_idx, params, parameter_index);
}

fn isSimpleParamsConstructorBodyGraphSafe(
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    method_extra: u32,
) bool {
    const extras = ast.extra_data.items;
    if (method_extra > extras.len or extras.len - method_extra <= ast_mod.MethodExtra.body) return false;

    const params_idx: ast_mod.NodeIndex = @enumFromInt(extras[method_extra + ast_mod.MethodExtra.params]);
    if (params_idx.isNone() or @intFromEnum(params_idx) >= ast.nodes.items.len) return false;
    const params = ast.getNode(params_idx);
    if (params.tag != .formal_parameters or params.data.list.start > extras.len or
        params.data.list.len > extras.len - params.data.list.start) return false;
    for (extras[params.data.list.start .. params.data.list.start + params.data.list.len], 0..) |raw_parameter_idx, parameter_offset| {
        if (!isSimpleConstructorParameterGraphSafe(
            ast,
            semantic,
            @enumFromInt(raw_parameter_idx),
            params.data.list,
            @intCast(parameter_offset),
        )) return false;
    }

    const body_idx: ast_mod.NodeIndex = @enumFromInt(extras[method_extra + ast_mod.MethodExtra.body]);
    if (body_idx.isNone() or @intFromEnum(body_idx) >= ast.nodes.items.len) return false;
    const body = ast.getNode(body_idx);
    if (body.tag != .block_statement) return false;
    const statements = body.data.list;
    if (statements.start > extras.len or statements.len > extras.len - statements.start) return false;
    for (extras[statements.start .. statements.start + statements.len]) |raw_statement_idx| {
        if (raw_statement_idx >= ast.nodes.items.len or
            !isSafeConstructorBodyStatement(ast, semantic, @enumFromInt(raw_statement_idx))) return false;
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

/// A public static field with a safe value expression, exact-bound static
/// member read, or exact-bound call is emitted as an exact class reference
/// plus an explicit global Object.defineProperty call. `this`, unresolved names,
/// and other call/member shapes stay on resync.
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

    const key_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra + ast_mod.PropertyExtra.key]);
    const init_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra + ast_mod.PropertyExtra.init]);
    if (key_idx.isNone() or @intFromEnum(key_idx) >= ast.nodes.items.len or
        init_idx.isNone() or @intFromEnum(init_idx) >= ast.nodes.items.len) return false;
    const key = ast.getNode(key_idx);
    switch (key.tag) {
        .identifier_reference => if (std.mem.eql(u8, ast.getText(key.span), "__proto__")) return false,
        .computed_property_key => {
            const key_value_idx = key.data.unary.operand;
            if (key_value_idx.isNone() or @intFromEnum(key_value_idx) >= ast.nodes.items.len or
                hasClassSelfReference(ast, semantic, key_value_idx) or
                (!isSafeConstructorValue(ast, semantic, key_value_idx) and
                    !isRetainableBoundStaticFieldMemberAccess(allocator, ast, semantic, key_value_idx) and
                    !isRetainableBoundStaticFieldCall(allocator, ast, semantic, key_value_idx))) return false;
        },
        else => return false,
    }
    return isSafeConstructorValue(ast, semantic, init_idx) or
        isRetainableBoundStaticFieldInitializerMemberAccess(allocator, ast, semantic, init_idx) or
        isRetainableBoundStaticFieldCall(allocator, ast, semantic, init_idx);
}

fn hasReachableStaticPublicClassField(ast: *const ast_mod.Ast) ?bool {
    if (ast.nodes.items.len == 0) return false;
    const root_idx = ast.transformed_root orelse @as(
        ast_mod.NodeIndex,
        @enumFromInt(@as(u32, @intCast(ast.nodes.items.len - 1))),
    );
    if (root_idx.isNone() or @intFromEnum(root_idx) >= ast.nodes.items.len) return null;
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
        const key_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra + ast_mod.PropertyExtra.key]);
        const init_idx: ast_mod.NodeIndex = @enumFromInt(extras[extra + ast_mod.PropertyExtra.init]);
        if (key_idx.isNone() or @intFromEnum(key_idx) >= ast.nodes.items.len or
            ast.nodes.items[@intFromEnum(key_idx)].tag == .private_identifier or
            init_idx.isNone() or @intFromEnum(init_idx) >= ast.nodes.items.len) continue;
        return true;
    }
    return false;
}

/// An ES5 class without a base preserves its graph when empty, when all members
/// are plain methods, or when plain methods are followed by one accessor or a
/// compatible getter/setter pair. One explicit constructor with only simple
/// identifier parameters or identifier parameters with literal defaults may
/// accompany plain methods and a terminal accessor group when its body contains
/// only audited declarations, expressions, control flow, and loops. Named or
/// anonymous class expressions are admitted only as direct initializers of a
/// top-level `var` declarator; other expression positions stay on reanalysis.
/// Anonymous expressions are safe because lowering registers the generated
/// constructor self binding and call-check reference in the exact output
/// function scope. Static fields must pass
/// `isRetainableSimpleStaticClassField`; computed/escaped keys and `super` stay
/// excluded.
fn isSimpleClass(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node: ast_mod.Node,
    source_binds_object: bool,
) bool {
    if (node.tag != .class_declaration and node.tag != .class_expression) return false;
    const extra = node.data.extra;
    const extras = ast.extra_data.items;
    if (extra > extras.len or extras.len - extra <= ast_mod.ClassExtra.body) return false;

    const name: ast_mod.NodeIndex = @enumFromInt(extras[extra + ast_mod.ClassExtra.name]);
    const super: ast_mod.NodeIndex = @enumFromInt(extras[extra + ast_mod.ClassExtra.super]);
    const body: ast_mod.NodeIndex = @enumFromInt(extras[extra + ast_mod.ClassExtra.body]);
    if ((!name.isNone() and (@intFromEnum(name) >= ast.nodes.items.len or
        ast.getNode(name).tag != .binding_identifier)) or
        (name.isNone() and node.tag != .class_expression) or !super.isNone() or
        body.isNone() or @intFromEnum(body) >= ast.nodes.items.len) return false;
    const body_node = ast.getNode(body);
    if (body_node.tag != .class_body) return false;
    const members = body_node.data.list;
    if (members.len == 0) return true;
    if (source_binds_object) return false;
    if (members.start > extras.len or members.len > extras.len - members.start) return false;

    var accessor_pair: ?struct { flags: u32, key_text: []const u8 } = null;
    var accessor_count: usize = 0;
    var accessors_started = false;
    var has_empty_explicit_constructor = false;
    for (extras[members.start .. members.start + members.len]) |raw_member_idx| {
        const member_idx: ast_mod.NodeIndex = @enumFromInt(raw_member_idx);
        if (member_idx.isNone() or @intFromEnum(member_idx) >= ast.nodes.items.len) return false;
        const member = ast.getNode(member_idx);
        if (isRetainableSimpleStaticClassField(allocator, ast, semantic, member)) continue;
        if (member.tag != .method_definition) return false;
        const method_extra = member.data.extra;
        if (method_extra > extras.len or extras.len - method_extra <= ast_mod.MethodExtra.flags) return false;
        const key_idx: ast_mod.NodeIndex = @enumFromInt(extras[method_extra + ast_mod.MethodExtra.key]);
        if (key_idx.isNone() or @intFromEnum(key_idx) >= ast.nodes.items.len) return false;
        const key = ast.getNode(key_idx);
        const flags = extras[method_extra + ast_mod.MethodExtra.flags];
        const is_plain_method = flags == 0 or flags == ast_mod.MethodFlags.is_static;
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
        if (std.mem.eql(u8, key_text, "constructor") or std.mem.eql(u8, key_text, "__proto__") or
            std.mem.indexOfScalar(u8, key_text, '\\') != null or methodHasSuperExpression(ast, member)) return false;
    }
    if (accessor_count > 2) return false;
    if (accessor_pair) |accessor| {
        // A method with the same key would replace or be replaced by the
        // accessor descriptor. Keep that duplicate-definition order on resync.
        const accessor_is_static = (accessor.flags & ast_mod.MethodFlags.is_static) != 0;
        for (extras[members.start .. members.start + members.len]) |raw_member_idx| {
            const member = ast.getNode(@enumFromInt(raw_member_idx));
            if (member.tag != .method_definition) continue;
            const method_extra = member.data.extra;
            const flags = extras[method_extra + ast_mod.MethodExtra.flags];
            const is_plain_method = flags == 0 or flags == ast_mod.MethodFlags.is_static;
            if (!is_plain_method or ((flags & ast_mod.MethodFlags.is_static) != 0) != accessor_is_static) continue;
            const key_idx: ast_mod.NodeIndex = @enumFromInt(extras[method_extra + ast_mod.MethodExtra.key]);
            const key_text = ast.getText(ast.getNode(key_idx).span);
            if (std.mem.eql(u8, accessor.key_text, key_text)) return false;
        }
    }
    return true;
}

fn isDirectTopLevelVarClassExpression(ast: *const ast_mod.Ast, target_raw: u32) bool {
    if (ast.nodes.items.len == 0) return false;
    const root_idx = ast.transformed_root orelse @as(
        ast_mod.NodeIndex,
        @enumFromInt(@as(u32, @intCast(ast.nodes.items.len - 1))),
    );
    if (root_idx.isNone() or @intFromEnum(root_idx) >= ast.nodes.items.len or
        ast.getNode(root_idx).tag != .program) return false;
    const statements = ast.getNode(root_idx).data.list;
    const extras = ast.extra_data.items;
    if (statements.start > extras.len or statements.len > extras.len - statements.start) return false;
    for (extras[statements.start .. statements.start + statements.len]) |raw_statement| {
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
            if (extras[declarator_extra + 2] == target_raw) return true;
        }
    }
    return false;
}

fn isTopLevelSimpleClass(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    node: ast_mod.Node,
    raw_node: usize,
    top_level_statements: *const std.DynamicBitSet,
    source_binds_object: bool,
) bool {
    const is_top_level = switch (node.tag) {
        .class_declaration => top_level_statements.isSet(raw_node),
        .class_expression => isDirectTopLevelVarClassExpression(ast, @intCast(raw_node)),
        else => false,
    };
    return is_top_level and isSimpleClass(allocator, ast, semantic, node, source_binds_object);
}

fn collectSimpleConstructorDefaultParameterNodes(
    ast: *const ast_mod.Ast,
    class_node: ast_mod.Node,
    defaults: *std.AutoHashMapUnmanaged(u32, void),
) bool {
    const extras = ast.extra_data.items;
    const class_extra = class_node.data.extra;
    if (class_extra > extras.len or extras.len - class_extra <= ast_mod.ClassExtra.body) return false;
    const body_idx: ast_mod.NodeIndex = @enumFromInt(extras[class_extra + ast_mod.ClassExtra.body]);
    if (body_idx.isNone() or @intFromEnum(body_idx) >= ast.nodes.items.len or
        ast.getNode(body_idx).tag != .class_body) return false;
    const members = ast.getNode(body_idx).data.list;
    if (members.start > extras.len or members.len > extras.len - members.start) return false;
    for (extras[members.start .. members.start + members.len]) |raw_member_idx| {
        if (raw_member_idx >= ast.nodes.items.len) return false;
        const member = ast.nodes.items[raw_member_idx];
        if (member.tag != .method_definition) continue;
        const method_extra = member.data.extra;
        if (method_extra > extras.len or extras.len - method_extra <= ast_mod.MethodExtra.flags) return false;
        const key_idx: ast_mod.NodeIndex = @enumFromInt(extras[method_extra + ast_mod.MethodExtra.key]);
        if (key_idx.isNone() or @intFromEnum(key_idx) >= ast.nodes.items.len) return false;
        const key = ast.getNode(key_idx);
        if (key.tag != .identifier_reference or !std.mem.eql(u8, ast.getText(key.span), "constructor")) continue;
        if (extras[method_extra + ast_mod.MethodExtra.flags] != 0 or
            extras.len - method_extra <= ast_mod.MethodExtra.params) return false;
        const params_idx: ast_mod.NodeIndex = @enumFromInt(extras[method_extra + ast_mod.MethodExtra.params]);
        if (params_idx.isNone() or @intFromEnum(params_idx) >= ast.nodes.items.len or
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

/// Arrow lowering edits the existing graph and creates only output function
/// scopes plus explicitly tracked captures. Native `await`, `yield`, and tagged
/// templates add no binding or scope edges. Keep these paths only for the
/// audited syntax subset; downlevel async/generator/template bodies stay on reanalysis.
fn canRetainGraphForAuditedSyntaxSubset(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    semantic: *const ModuleSemanticData,
    options: TransformOptions,
) bool {
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
    var top_level_statements = ast_walk.topLevelStatementMask(ast) catch return false;
    defer top_level_statements.deinit();

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
    if (options.unsupported.block_scoping) {
        for (reachable_nodes) |raw_idx| {
            const node = ast.nodes.items[raw_idx];
            if (node.tag == .for_statement) {
                const extra = node.data.extra;
                if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 4) return false;
                const initializer: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra]);
                if (!initializer.isNone() and @intFromEnum(initializer) < ast.nodes.items.len and
                    ast.nodes.items[@intFromEnum(initializer)].tag == .variable_declaration and
                    ast.variableDeclarationKind(ast.nodes.items[@intFromEnum(initializer)]).isLexical())
                {
                    if (!isSafeRetainedLexicalForStatement(ast, semantic, node)) return false;
                    lowered_classic_for_heads.put(ast.allocator, @intFromEnum(initializer), {}) catch return false;
                }
            }
            if (node.tag != .for_in_statement and
                !(node.tag == .for_of_statement and options.unsupported.for_of)) continue;
            const head = node.data.ternary.a;
            if (head.isNone() or @intFromEnum(head) >= ast.nodes.items.len) return false;
            const head_node = ast.nodes.items[@intFromEnum(head)];
            if (head_node.tag == .variable_declaration and
                ast.variableDeclarationKind(head_node) != .@"var")
            {
                const head_raw = @intFromEnum(head);
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
        if (head.isNone() or @intFromEnum(head) >= ast.nodes.items.len) return false;
        if (ast.nodes.items[@intFromEnum(head)].tag == .variable_declaration) {
            destructuring_loop_heads.put(ast.allocator, @intFromEnum(head), {}) catch return false;
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
                    @enumFromInt(binding_raw),
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
                assignment.data.binary.flags != @intFromEnum(token_mod.Kind.eq)) continue;
            const target = assignment.data.binary.left;
            if (target.isNone() or @intFromEnum(target) >= ast.nodes.items.len) return false;
            const target_tag = ast.nodes.items[@intFromEnum(target)].tag;
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
            const default_idx: ast_mod.NodeIndex = @enumFromInt(default_raw);
            if (!default_idx.isNone() and @intFromEnum(default_idx) >= ast.nodes.items.len) return false;
            const pattern_tag = ast.nodes.items[pattern_raw].tag;
            if ((pattern_tag != .array_pattern and pattern_tag != .object_pattern) or
                !default_idx.isNone()) continue;
            const pattern_nodes = ast_walk.collectReachableNodeIndicesFrom(
                ast.allocator,
                ast,
                @enumFromInt(pattern_raw),
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
                    @enumFromInt(parameter_raw),
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

    // Plain computed data properties, synchronous object methods, computed
    // accessors without `super`, and audited static class-field keys lower
    // through tracked temps and output scopes. Accessor `super` may add a
    // runtime helper module, so it stays on reanalysis. Async/generator methods
    // and unaudited class keys remain gated out.
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
                const key: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[key_at]);
                if (key.isNone() or @intFromEnum(key) >= ast.nodes.items.len or
                    ast.nodes.items[@intFromEnum(key)].tag != .computed_property_key or
                    !isRetainableSimpleStaticClassField(allocator, ast, semantic, owner_node)) continue;
                computed_object_keys.put(ast.allocator, @intFromEnum(key), .static_class_field) catch return false;
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
                        const unsupported_method_flags = ast_mod.MethodFlags.is_async | ast_mod.MethodFlags.is_generator;
                        if ((flags & unsupported_method_flags) != 0) break :blk null;
                        const is_accessor = (flags & (ast_mod.MethodFlags.is_getter | ast_mod.MethodFlags.is_setter)) != 0;
                        break :blk .{
                            .node = @enumFromInt(ast.extra_data.items[method_extra + ast_mod.MethodExtra.key]),
                            .owner = if (is_accessor) .accessor else .method,
                        };
                    },
                    else => null,
                };
                const computed = candidate orelse continue;
                if (computed.node.isNone() or @intFromEnum(computed.node) >= ast.nodes.items.len) return false;
                if (ast.nodes.items[@intFromEnum(computed.node)].tag != .computed_property_key) continue;
                if (computed.owner == .accessor and methodHasSuperExpression(ast, member)) continue;
                computed_object_keys.put(ast.allocator, @intFromEnum(computed.node), computed.owner) catch return false;
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

    // Default-parameter lowering replaces only these literal assignment
    // patterns with exact reads/writes of the same parameter SymbolId. Admit
    // those nodes only when their owning top-level class already passes the
    // complete retained-graph preflight. Cache the class decisions so the
    // node walk below does not repeat the full class-body check.
    var retained_simple_class_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer retained_simple_class_nodes.deinit(ast.allocator);
    var lowered_simple_constructor_default_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer lowered_simple_constructor_default_nodes.deinit(ast.allocator);
    if (options.unsupported.class) {
        for (reachable_nodes) |raw_idx| {
            const class_node = ast.nodes.items[raw_idx];
            if (class_node.tag != .class_declaration and class_node.tag != .class_expression) continue;
            if (!isTopLevelSimpleClass(
                allocator,
                ast,
                semantic,
                class_node,
                raw_idx,
                &top_level_statements,
                source_binds_object,
            )) continue;
            retained_simple_class_nodes.put(ast.allocator, raw_idx, {}) catch return false;
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
    var found_native_tagged_template = false;
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
                if ((ast.extra_data.items[flags_at] & ast_mod.ArrowFlags.is_async) != 0) return false;
                if (options.unsupported.arrow) found_arrow = true;
            },
            .function_declaration, .function_expression, .function => {
                const flags_at = node.data.extra + ast_mod.FunctionExtra.flags;
                if (flags_at >= ast.extra_data.items.len) return false;
                const flags = ast.extra_data.items[flags_at];
                const is_async = (flags & ast_mod.FunctionFlags.is_async) != 0;
                const is_generator = (flags & ast_mod.FunctionFlags.is_generator) != 0;
                if ((is_generator and (is_async or options.unsupported.generator)) or
                    (is_async and options.unsupported.async_await)) return false;
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
                const binding: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[node.data.extra]);
                if (binding.isNone() or @intFromEnum(binding) >= ast.nodes.items.len) return false;
                const binding_tag = ast.nodes.items[@intFromEnum(binding)].tag;
                if (binding_tag == .binding_identifier) continue;
                if (binding_tag != .array_pattern and binding_tag != .object_pattern) return false;
                if (options.unsupported.destructuring) {
                    if (lowered_var_destructuring_declarators.contains(raw_idx) and
                        lowered_var_destructuring_nodes.contains(@intFromEnum(binding)))
                    {
                        found_lowered_var_destructuring = true;
                    } else if (lowered_parameter_destructuring_nodes.contains(@intFromEnum(binding))) {
                        found_lowered_parameter_destructuring = true;
                    } else return false;
                }
            },
            .formal_parameter => {
                const extra = node.data.extra;
                if (extra + 2 >= ast.extra_data.items.len) return false;
                const pattern: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra]);
                const default_value: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra + 2]);
                if (pattern.isNone() or @intFromEnum(pattern) >= ast.nodes.items.len or
                    (!default_value.isNone() and options.unsupported.default_params)) return false;
                const pattern_tag = ast.nodes.items[@intFromEnum(pattern)].tag;
                if (pattern_tag != .binding_identifier) {
                    if (pattern_tag != .array_pattern and pattern_tag != .object_pattern) return false;
                    if (options.unsupported.destructuring) {
                        if (lowered_parameter_destructuring_nodes.contains(@intFromEnum(pattern))) {
                            found_lowered_parameter_destructuring = true;
                        } else return false;
                    }
                    if (pattern_tag == .object_pattern and options.unsupported.object_spread and
                        ast.nodeListSplitRest(ast.nodes.items[@intFromEnum(pattern)].data.list).rest_operand != null)
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
                const operator: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                if (options.unsupported.exponentiation and operator == .star2_eq) {
                    // The transform editor tracks both source identifiers and
                    // generated member receiver/key temps by exact identity.
                    if (!isRetainableAssignmentTarget(ast, semantic, node.data.binary.left))
                        return false;
                    found_lowered_exponentiation = true;
                }
                if (options.unsupported.logical_assignment and
                    (operator == .question2_eq or operator == .pipe2_eq or operator == .amp2_eq))
                {
                    // Member receiver/key temps and the value capture for ??=
                    // are registered by the same transform semantic editor.
                    if (!isRetainableAssignmentTarget(ast, semantic, node.data.binary.left))
                        return false;
                    found_lowered_logical_assignment = true;
                }
            },
            .binary_expression, .logical_expression => {
                const operator: token_mod.Kind = @enumFromInt(node.data.binary.flags);
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
                    ast_mod.spineHasOptionalChain(ast, @enumFromInt(raw_idx)))
                {
                    if (node.tag != .call_expression or
                        !isRetainableOptionalCall(ast, semantic, @enumFromInt(raw_idx))) return false;
                    found_lowered_optional_chaining = true;
                }
                if (options.unsupported.spread and hasDirectSpreadElement(ast, node)) {
                    if (!hasOnlyArrayLiteralSpreadOperands(ast, node)) return false;
                    found_lowered_array_spread = true;
                }
            },
            .static_member_expression, .computed_member_expression => {
                if (options.unsupported.optional_chaining and
                    ast_mod.spineHasOptionalChain(ast, @enumFromInt(raw_idx)))
                {
                    // Optional member lowering evaluates this property once
                    // inside the null-checked branch. Audited ordinary member
                    // and call tails can follow; optional calls retain resync.
                    if (!isRetainableOptionalChainMemberAccess(ast, semantic, @enumFromInt(raw_idx)))
                        return false;
                    found_lowered_optional_chaining = true;
                }
            },
            .object_expression => {
                if (hasDirectSpreadElement(ast, node)) {
                    if (options.unsupported.object_spread) {
                        // Lowering emits Object.assign. A source Object binding
                        // changes which function that generated reference calls.
                        if (source_binds_object) return false;
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
                if (options.unsupported.async_await) return false;
                found_native_await = true;
            },
            .yield_expression => {
                if (options.unsupported.generator) return false;
                found_native_generator = true;
            },
            .tagged_template_expression => {
                if (options.unsupported.template_literal) return false;
                found_native_tagged_template = true;
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
                if (!head.isNone() and lowered_for_in_heads.contains(@intFromEnum(head))) {
                    found_lowered_for_in = true;
                } else {
                    found_native_for_in = true;
                }
            },
            .for_statement => {
                const extra = node.data.extra;
                if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra < 4) return false;
                const initializer: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra]);
                if (!initializer.isNone() and lowered_classic_for_heads.contains(@intFromEnum(initializer)))
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
                const key: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[key_at]);
                if (key.isNone() or @intFromEnum(key) >= ast.nodes.items.len) return false;
                if (ast.nodes.items[@intFromEnum(key)].tag == .private_identifier) {
                    if (options.unsupported.class_private_field) return false;
                } else if (options.unsupported.class_field or options.unsupported.class) {
                    if (source_binds_object or !isRetainableSimpleStaticClassField(allocator, ast, semantic, node)) return false;
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
                // `new.target` is safe here only when the target preserves it
                // natively. Lowering it can synthesize a different reference
                // expression and must use the semantic resync path.
                if (node.data.none == 1 and options.unsupported.new_target) return false;
            },
            .method_definition => {
                const key_at = node.data.extra + ast_mod.MethodExtra.key;
                if (key_at >= ast.extra_data.items.len) return false;
                const key: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[key_at]);
                if (key.isNone() or @intFromEnum(key) >= ast.nodes.items.len) return false;
                if (ast.nodes.items[@intFromEnum(key)].tag == .private_identifier and
                    options.unsupported.class_private_method) return false;
                const flags_at = node.data.extra + ast_mod.MethodExtra.flags;
                if (flags_at >= ast.extra_data.items.len) return false;
                const flags = ast.extra_data.items[flags_at];
                const is_async = (flags & ast_mod.MethodFlags.is_async) != 0;
                const is_generator = (flags & ast_mod.MethodFlags.is_generator) != 0;
                if ((is_async and is_generator and options.unsupported.async_generator) or
                    (is_async and options.unsupported.async_await) or
                    (is_generator and options.unsupported.generator)) return false;
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
            // Parent-specific checks above admit only audited, helper-free
            // array-literal spread lowering; other downlevel spread stays on
            // semantic reanalysis.
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
                    // source-graph preflight. Keep the same Object-shadowing
                    // guard as source object spreads, and record this lowered
                    // global edge in the retained-graph scan.
                    if (source_binds_object) return false;
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
    return found_arrow or found_native_await or found_native_generator or found_native_tagged_template or
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
        found_lowered_optional_catch_binding;
}

/// A retained prepass graph may absorb only the `__values`/`__asyncValues`
/// virtual imports introduced by audited iterator lowering and `__read`/`__rest`
/// imports introduced by audited destructuring/object-rest lowering.
/// Any other runtime helper can indicate an independently lowered construct,
/// so keep that module on semantic resync.
fn runtimeHelpersSafeForRetainedGraph(
    helpers: @import("../../transformer/runtime_helper_bits.zig").RuntimeHelpers,
) bool {
    var other_helpers = helpers;
    other_helpers.values = false;
    other_helpers.async_values = false;
    other_helpers.read = false;
    other_helpers.rest = false;
    other_helpers.class_call_check = false;
    return !other_helpers.hasAny();
}

fn hasClassFieldSyntax(ast: *const ast_mod.Ast) bool {
    for (ast.nodes.items) |node| {
        if (node.tag == .property_definition) return true;
    }
    return false;
}

fn canKeepPrepassSemanticGraph(
    self: anytype,
    module: *const Module,
    options: TransformOptions,
    plugins: anytype,
) bool {
    if (module.ast == null or module.semantic == null) return false;
    const ast = &module.ast.?;
    const semantic = &module.semantic.?;
    var top_level_statements = ast_walk.topLevelStatementMask(ast) catch return false;
    defer top_level_statements.deinit();
    if (self.worklet_transform or self.emotion or
        self.plugins.len != 0 or plugins.len != 0 or options.plugins.len != 0) return false;
    // The displayName/namespace styled-components visitor only wraps existing
    // expressions and preserves every source binding/reference. CSS-prop mode
    // injects a new package import, whose module-graph edge must still be
    // reconciled by the full prepass.
    if (options.styled_components_css_prop) return false;
    if (!options.strip_types) return false;
    const classic_jsx = ast.has_jsx and options.jsx_transform and options.jsx_runtime == .classic;
    const automatic_jsx = ast.has_jsx and options.jsx_transform and options.jsx_runtime == .automatic;
    const automatic_dev_jsx = ast.has_jsx and options.jsx_transform and options.jsx_runtime == .automatic_dev;
    const graph_editable_jsx = classic_jsx or automatic_jsx or automatic_dev_jsx;
    const safe_graph_subset = options.unsupported.hasAny() and
        canRetainGraphForAuditedSyntaxSubset(self.allocator, ast, semantic, options);
    if ((ast.has_jsx and !graph_editable_jsx) or ast.has_decorator) return false;
    // Whitespace minification changes emission and helper spellings, but the
    // transformer records those helper identities in the edited graph. Unlike
    // syntax minification, this option does not remove or replace AST nodes.
    if ((options.unsupported.hasAny() and !safe_graph_subset) or options.minify_syntax or
        options.drop_console or options.drop_debugger or
        options.drop_labels.len != 0 or define_mod.astUsesDefine(ast, options.define) or options.module_specifier_map.len != 0 or
        (!options.use_define_for_class_fields and hasClassFieldSyntax(ast)) or options.experimental_decorators or
        options.emit_decorator_metadata or options.tla_chunk_wrapped or options.tla_export_decl_deferrable) return false;
    const has_top_level_await = module.uses_top_level_await or module.self_uses_top_level_await;
    // The parser already records native TLA exactly. Lowered TLA moves await
    // into a generated async IIFE, so keep that case on the full resync path.
    if (has_top_level_await and options.unsupported.top_level_await) return false;
    if (!hasSupportedTopLevelExportDeclarations(module)) return false;
    if (!hasStableRuntimeImports(ast, options)) return false;

    const safe_styled_components = options.styled_components and !options.styled_components_css_prop;
    var found_transform = graph_editable_jsx or safe_graph_subset or safe_styled_components or options.react_refresh;
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
                const node_idx: ast_mod.NodeIndex = @enumFromInt(@as(u32, @intCast(raw_node_idx)));
                if (!isSupportedPlainExportAll(ast, node_idx)) return false;
                found_transform = true;
            },
            // These constructs can alter the import/export graph or create
            // dynamic-name environments independently of Flow match lowering.
            .ts_namespace_export_declaration,
            .with_statement,
            => return false,
            .yield_expression => {
                // Native sync generators preserve the source function scope.
                // The reachable-node subset check rejects async and downlevel
                // generators before this module can retain its semantic graph.
                if (options.unsupported.generator) return false;
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
                // The audited subset validates direct class declarations and
                // direct top-level `var` initializers for named or anonymous
                // class expressions.
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
    const can_keep_semantic_graph = object_spread_scan != null and exponentiation_scan != null and
        downlevel_static_public_class_field_scan != null and
        canKeepPrepassSemanticGraph(self, module, opts, merged_plugins);
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
    transformer.record_explicit_global_references =
        flow_match_generated_globals.has_match or has_lowered_object_spread or has_lowered_exponentiation or
        (downlevel_static_public_class_field_scan orelse
            (opts.unsupported.class or opts.unsupported.class_field));

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
            const source_root: ast_mod.NodeIndex = @enumFromInt(parser_node_count - 1);
            const source_scope_owner_audit = coverage.checkExactWithDeclarationAnchors(
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
    if (transformer.used_unsupported_exponentiation) {
        self.addDiag(.exponentiation_dynamic_scope, .warning, module.path, Span.EMPTY, .parse, TransformOptions.exponentiation_dynamic_scope_msg, null);
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

    // Type erasure, Flow match lowering, TypeScript enums, supported JSX,
    // bounded named-class cases, and audited iterator/destructuring/spread
    // subsets preserve the edited semantic graph. JSX and syntax lowering may
    // add synthetic helper imports, so refresh module graph metadata without
    // replacing that graph.
    if (can_keep_semantic_graph and runtimeHelpersSafeForRetainedGraph(transformer.runtime_helpers)) {
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
        const generated_globals_recorded =
            (!flow_match_generated_globals.array or module.semantic.?.unresolved_references.contains("Array")) and
            (!flow_match_generated_globals.object or module.semantic.?.unresolved_references.contains("Object")) and
            (!lowered_object_spread_global or module.semantic.?.unresolved_references.contains("Object")) and
            (!lowered_exponentiation_global or module.semantic.?.unresolved_references.contains("Math")) and
            (!lowered_simple_static_class_field_global or module.semantic.?.unresolved_references.contains("Object"));
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
        sem.symbol_ids,
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
        if (node_index.isNone() or @intFromEnum(node_index) >= ast.nodes.items.len) {
            return error.InvalidMaterializedNode;
        }
        if (!isMaterializedPrimitiveLiteral(ast.nodes.items[@intFromEnum(node_index)].tag)) {
            return error.InvalidMaterializedNode;
        }
        // The materializer supplies the exact read sites it changed. Missing
        // identity evidence fails closed into the existing full-analyzer path.
        try editor.removeReference(node_index);
    }

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
        if (symbol_id == value_symbol.?) value_binding_node = @enumFromInt(node_index);
        if (symbol_id == shadow_parameter_symbol.?) shadow_parameter_node = @enumFromInt(node_index);
    }
    try std.testing.expect(!value_binding_node.isNone());
    try std.testing.expect(!shadow_parameter_node.isNone());

    var materialized_nodes: [2]ast_mod.NodeIndex = undefined;
    var materialized_count: usize = 0;
    for (analyzer.references.items) |reference| {
        if (@intFromEnum(reference.symbol_id) != value_symbol.? or reference.node_index.isNone()) continue;
        const node_index = @intFromEnum(reference.node_index);
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

    var module = Module.init(@enumFromInt(0), "test.js");
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
    try std.testing.expectEqual(value_symbol.?, semantic.symbol_ids[@intFromEnum(value_binding_node)].?);
    try std.testing.expectEqual(
        shadow_parameter_symbol.?,
        semantic.symbol_ids[@intFromEnum(shadow_parameter_node)].?,
    );
    for (materialized_nodes[0..materialized_count]) |node_index| {
        const raw = @intFromEnum(node_index);
        try std.testing.expect(semantic.symbol_ids[raw] == null);
        try std.testing.expect(module.transform_cache.?.symbol_ids[raw] == null);
    }

    var value_reference_count: usize = 0;
    var shadow_parameter_reference_count: usize = 0;
    for (semantic.references) |reference| {
        if (@intFromEnum(reference.symbol_id) == value_symbol.?) value_reference_count += 1;
        if (@intFromEnum(reference.symbol_id) == shadow_parameter_symbol.?) shadow_parameter_reference_count += 1;
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

fn testRenameSymbol(kind: SemanticSymbolKind, is_default_export: bool) SemanticSymbol {
    return .{
        .name = Span.EMPTY,
        .scope_id = .none,
        .kind = kind,
        .decl_flags = .{ .is_default_export = is_default_export },
        .declaration_span = Span.EMPTY,
    };
}
