//! Actual edits performed by a producer in one stable AST domain. This is a
//! receipt, not permission to reconstruct missing lexical identities.
const ast_mod = @import("../parser/ast.zig");
const Reference = @import("symbol.zig").Reference;
const ScopeId = @import("scope.zig").ScopeId;
const Provenance = @import("node_scope_provenance.zig").Entry;

pub const ReferenceChange = struct {
    before: ?Reference,
    after: ?Reference,
};

pub const OwnerChange = struct {
    source_owner: ast_mod.NodeIndex,
    scope: ScopeId,
    target_owner: ?ast_mod.NodeIndex,
    effect: enum { move, empty_arrow_elide },
    parent: ?ScopeId,
};

pub const ProvenanceChange = struct {
    node: ast_mod.NodeIndex,
    before: ?Provenance,
    after: ?Provenance,
};

pub const Copy = struct {
    source: ast_mod.NodeIndex,
    target: ast_mod.NodeIndex,
    /// Payloads captured before the actual overwrite, in event order.
    source_node: ast_mod.Node,
    target_node: ast_mod.Node,
    source_reference: ?Reference,
    source_owner: ?ScopeId,
    /// Reachability measured after the producer has finished all edits.
    source_reachable: bool,
    target_reachable: bool,
};

pub const MaterializedRead = struct {
    node: ast_mod.NodeIndex,
    before_node: ast_mod.Node,
    after_node: ast_mod.Node,
    before_reference: Reference,
    before_symbol_id: u32,
};

pub const ApplicationReceipt = struct {
    /// The physical, stable candidate header bound before the first edit.
    domain: *const ast_mod.Ast,
    reference_changes: []const ReferenceChange,
    owner_changes: []const OwnerChange,
    provenance_changes: []const ProvenanceChange,
    copies: []const Copy,
    materialized_reads: []const MaterializedRead = &.{},
    function_name_elisions: []const @import("function_name_retirement.zig").Elision = &.{},
};
