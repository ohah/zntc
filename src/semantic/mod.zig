//! ZTS Semantic Analysis
//!
//! AST에서 스코프/심볼을 구축하고 의미 검증을 수행한다.
//! 파서와 분리된 별도 패스 (D038, oxc 방식).
//!
//! 주요 기능:
//!   - 스코프 트리 구축 (D052: 플랫 배열 + 부모 인덱스)
//!   - 심볼 수집 (D053: 최소 심볼 모델)
//!   - 변수 재선언 검증 (let/const 중복, var과 let 충돌 등)
//!
//! 사용법:
//!   const ast = parser.ast;
//!   var analyzer = SemanticAnalyzer.init(allocator, &ast);
//!   defer analyzer.deinit();
//!   analyzer.analyze();
//!   // analyzer.errors 확인

pub const analyzer = @import("analyzer.zig");
pub const checker = @import("checker.zig");
pub const scope = @import("scope.zig");
pub const symbol = @import("symbol.zig");

pub const SemanticAnalyzer = analyzer.SemanticAnalyzer;
pub const Diagnostic = @import("../diagnostic.zig").Diagnostic;
pub const Scope = scope.Scope;
pub const ScopeId = scope.ScopeId;
pub const ScopeKind = scope.ScopeKind;
pub const Symbol = symbol.Symbol;
pub const SymbolId = symbol.SymbolId;
pub const SymbolKind = symbol.SymbolKind;
pub const SymbolFlags = symbol.DeclFlags;
pub const Reference = symbol.Reference;
pub const ReferenceFlags = symbol.ReferenceFlags;

test {
    _ = analyzer;
    _ = checker;
    _ = scope;
    _ = symbol;

    // test files
    _ = @import("analyzer_test.zig");
    _ = @import("checker_test.zig");
    _ = @import("scope_test.zig");
    _ = @import("symbol_test.zig");
}
