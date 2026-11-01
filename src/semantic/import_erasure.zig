//! Birth facts for actual import binding erasure. None of these records select
//! a SymbolId by spelling or claim that a bound source read was initially free.
const ast = @import("../parser/ast.zig");
const symbols = @import("symbol.zig");

pub const Binding = struct {
    declaration: ast.NodeIndex,
    declaration_node: ast.Node,
    specifier: ast.NodeIndex,
    specifier_node: ast.Node,
    local: ast.NodeIndex,
    local_node: ast.Node,
    declaration_type_only: bool,
    specifier_type_only: bool,
    policy: enum { declaration_type_only, specifier_type_only, unused },
};

/// An actual bound runtime-use row immediately before erasure. The enclosing
/// Entry.scope follows exact owner/copy edits; this before tuple stays intact.
/// Leaf payload is explicit so structural equality never compares an untagged
/// Node.Data union or silently changes an identifier's StringValue.
pub const ExternalOrigin = struct {
    binding_symbol: symbols.SymbolId,
    before: symbols.Reference,
    before_tag: ast.Node.Tag,
    before_name: ast.StringRef,
    before_span: @import("../lexer/token.zig").Span,
};

/// Compare only the payload selected by the parser's actual import role.
pub fn equalNode(a: ast.Node, b: ast.Node) bool {
    const std = @import("std");
    if (a.tag != b.tag or !std.meta.eql(a.span, b.span)) return false;
    return switch (a.tag) {
        .binding_identifier, .identifier_reference, .import_default_specifier, .import_namespace_specifier => std.meta.eql(a.data.string_ref, b.data.string_ref),
        .import_specifier => std.meta.eql(a.data.binary, b.data.binary),
        .import_declaration => a.data.extra == b.data.extra,
        else => false,
    };
}

pub fn validatesBinding(tree: *const ast.Ast, binding: Binding) bool {
    const module = @import("../parser/module.zig");
    inline for (.{ "declaration", "specifier", "local" }) |field| {
        const node = @field(binding, field);
        if (node.isNone() or @backingInt(node) >= tree.nodes.items.len) return false;
        if (!equalNode(tree.getNode(node), @field(binding, field ++ "_node"))) return false;
    }
    if (binding.declaration_node.tag != .import_declaration) return false;
    const start = binding.declaration_node.data.extra;
    if (start > tree.extra_data.items.len or tree.extra_data.items.len - start < 6) return false;
    const decl = module.readImportDeclExtras(tree, start);
    if (decl.specs_start > tree.extra_data.items.len or decl.specs_len > tree.extra_data.items.len - decl.specs_start or decl.is_type_only != binding.declaration_type_only) return false;
    var count: usize = 0;
    for (tree.extra_data.items[decl.specs_start..][0..decl.specs_len]) |raw| if (raw == @backingInt(binding.specifier)) {
        count += 1;
    };
    if (count != 1) return false;
    const spec = binding.specifier_node;
    const local = switch (spec.tag) {
        .import_specifier => spec.data.binary.right,
        .import_default_specifier, .import_namespace_specifier => binding.specifier,
        else => return false,
    };
    const inline_type = spec.tag == .import_specifier and (spec.data.binary.flags & module.SPEC_FLAG_TYPE_ONLY) != 0;
    if (local != binding.local or inline_type != binding.specifier_type_only) return false;
    return switch (binding.policy) {
        .declaration_type_only => binding.declaration_type_only,
        .specifier_type_only => !binding.declaration_type_only and binding.specifier_type_only,
        .unused => !binding.declaration_type_only and !binding.specifier_type_only,
    };
}
