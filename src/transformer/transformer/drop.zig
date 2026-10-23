//! Drop-option filters for Transformer.

const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const drop_scan = @import("../drop_scan.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;

pub fn shouldDropNode(self: *const Transformer, node: Node) bool {
    if (self.options.drop_debugger and node.tag == .debugger_statement) return true;
    if (self.options.drop_console and node.tag == .expression_statement and isConsoleCall(self, node)) return true;
    if (self.options.drop_labels.len > 0 and node.tag == .labeled_statement) return hasDroppedLabel(self, node);
    return false;
}

/// expression_statement가 console.* 호출인지 판별.
/// console.log(...), console.warn(...), console.error(...) 등.
pub fn isConsoleCall(self: *const Transformer, node: Node) bool {
    return isConsoleCallInAst(self.ast, node);
}

pub fn isConsoleCallInAst(ast: *const ast_mod.Ast, node: Node) bool {
    return drop_scan.isConsoleCallInAst(ast, node);
}

pub fn isNoSubstitutionTemplateLiteral(ast: *const ast_mod.Ast, index: ast_mod.NodeIndex) bool {
    return drop_scan.isNoSubstitutionTemplateLiteral(ast, index);
}

fn hasDroppedLabel(self: *const Transformer, node: Node) bool {
    return drop_scan.isDroppedLabel(self.ast, node, self.options.drop_labels);
}
