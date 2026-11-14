//! Initialize only producer-owned lexical sentinels before the namespace yield.
//! The original Source body is emitted unchanged, including its harmless resets.
const std = @import("std");
const Module = @import("../module.zig").Module;
const Linker = @import("../linker.zig").Linker;
const Codegen = @import("../../codegen/codegen.zig").Codegen;
const ast = @import("../../parser/ast.zig");

fn marker(cg: *Codegen, module: *const Module, linker: *const Linker, binding: ast.NodeIndex, initializer: ast.NodeIndex) !bool {
    if (binding.isNone() or initializer.isNone()) return false;
    const cache = module.transform_cache orelse return false;
    // This exact reference was produced by makeRuntimeHelperRef. A user import
    // of the same provider does not grant its Source reference this role.
    if (std.sort.binarySearch(u32, cache.helper_ref_nodes, @backingInt(initializer), struct {
        fn order(lhs: u32, rhs: u32) std.math.Order {
            return std.math.order(lhs, rhs);
        }
    }.order) == null) return false;
    const ids = cg.options.semantic_symbol_ids;
    if (@backingInt(binding) >= ids.len or @backingInt(initializer) >= ids.len) return false;
    const source_sid = ids[@backingInt(binding)] orelse return false;
    const helper_sid = ids[@backingInt(initializer)] orelse return false;
    const semantic = module.semantic orelse return false;
    if (source_sid >= semantic.symbols.items.len) return false;
    const source = semantic.symbols.items[source_sid];
    if (source.kind != .variable_let and source.kind != .variable_const and source.kind != .class_decl) return false;
    const actual = try @import("../lexical_initialization_builtin.zig").exact(linker.graph);
    for (module.import_bindings) |imported| {
        if (imported.local_symbol.semanticIndex() != helper_sid or imported.import_record_index >= module.import_records.len) continue;
        const record = module.import_records[imported.import_record_index];
        if (record.resolved != actual.module) continue;
        const provider = linker.graph.getModule(actual.module) orelse return error.InvalidSynchronousModuleHelper;
        const known = linker.graph.lexical_tdz_builtin orelse return error.InvalidSynchronousModuleHelper;
        if (known.export_index >= provider.export_bindings.len) return error.InvalidSynchronousModuleHelper;
        if (!std.mem.eql(u8, imported.imported_name, provider.export_bindings[known.export_index].exported_name)) continue;
        if (imported.callsite_target) |target| try @import("../runtime_callsite_targets.zig").validateTargetRole(linker.graph, target);
        _ = try module.checkedImportBindingSourceSymbol(imported);
        return true;
    }
    return false;
}

pub fn append(cg: *Codegen, module: *const Module, linker: *const Linker, root: ast.NodeIndex) !void {
    const program = cg.ast.getNode(root);
    if (program.tag != .program) return error.InvalidSynchronousModuleOwner;
    var statements = cg.ast.iterateExtraList(program.data.list);
    while (statements.next()) |statement| {
        const node = cg.ast.getNode(statement);
        if (node.tag == .variable_declaration) {
            if (cg.ast.variableDeclarationKind(node) != .@"var") continue;
            const start = cg.ast.readExtra(node.data.extra, 1);
            const len = cg.ast.readExtra(node.data.extra, 2);
            for (cg.ast.extra_data.items[start..][0..len]) |raw| {
                const declarator = cg.ast.getNode(@fromBackingInt(raw));
                if (declarator.tag != .variable_declarator) continue;
                const binding = cg.ast.readExtraNode(declarator.data.extra, 0);
                const value = cg.ast.readExtraNode(declarator.data.extra, 2);
                if (!try marker(cg, module, linker, binding, value)) continue;
                try cg.write("var ");
                try cg.emitNode(@fromBackingInt(raw));
                try cg.write(";\n");
            }
        } else if (node.tag == .expression_statement) {
            const expression = cg.ast.getNode(node.data.unary.operand);
            if (expression.tag != .assignment_expression) continue;
            if (!try marker(cg, module, linker, expression.data.binary.left, expression.data.binary.right)) continue;
            try cg.emitNode(statement);
            try cg.write("\n");
        }
    }
}
