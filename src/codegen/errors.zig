/// Semantic invariants that can make code generation fail independently of
/// allocator failures.
pub const Error = error{
    InvalidCompilerStatementInsertion,
    InvalidNativeModuleUsingContext,
    InvalidNativeModuleImportProjection,
    InvalidNativeModuleStorageProjection,
    MissingEnumIifeParameterSymbol,
    MissingNamespaceIifeParameterSymbol,
    MissingGeneratedIifeParameterFinalName,
    InvalidNamespacePrefixSymbol,
    InvalidEnumIifeMemberSymbol,
    MissingNamespaceDeclarationSymbol,
    InvalidNamespaceDeclarationSymbol,
    MissingNamespaceInlineObjectRename,
    InvalidNamespaceInlineObjectRename,
};
