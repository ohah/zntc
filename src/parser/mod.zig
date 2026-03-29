//! ZTS Parser
//!
//! 토큰 스트림을 AST로 변환한다.
//! 2패스: parse → visit (D040).

pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");

pub const Ast = ast.Ast;
pub const Node = ast.Node;
pub const Tag = ast.Node.Tag;
pub const NodeIndex = ast.NodeIndex;
pub const NodeList = ast.NodeList;
pub const Parser = parser.Parser;
pub const Diagnostic = @import("../diagnostic.zig").Diagnostic;

test {
    _ = ast;
    _ = parser;

    // test files
    _ = @import("parser_test.zig");
    _ = @import("ast_test.zig");
}
