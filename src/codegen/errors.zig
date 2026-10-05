/// Semantic invariants that can make code generation fail independently of
/// allocator failures.
pub const Error = error{MissingNamespaceIifeParameterSymbol};
