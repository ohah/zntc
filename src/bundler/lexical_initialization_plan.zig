//! Exact provider identities consumed by namespace publication. Public keys
//! select an ExportBinding; they never recover a source SymbolId by spelling.
const Module = @import("module.zig").Module;
const ExportBinding = @import("module.zig").ExportBinding;
const SymbolRef = @import("symbol.zig").SymbolRef;
const Owner = @import("codegen_output_domain.zig").Owner;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const ModuleIndex = @import("types.zig").ModuleIndex;

pub const ReadPlan = struct {
    module: *const Module,
    index: ModuleIndex,
    owner: Owner,
    source_node: NodeIndex,
    source: SymbolRef,
    initialized: SymbolRef,

    pub fn fromExport(provider: *const Module, binding: ExportBinding) error{InvalidLexicalInitializationOwner}!?ReadPlan {
        if (binding.kind != .local) return null;
        const semantic = provider.semantic orelse return null;
        const sid = provider.exportBindingSemanticIndex(binding) orelse return error.InvalidLexicalInitializationOwner;
        const role = semantic.symbols.items[sid].lexical_initialization;
        if (role.state == .native) {
            if (!role.flag.isNone() or semantic.symbols.items[sid].binding_instantiation.lexical_initialization)
                return error.InvalidLexicalInitializationOwner;
            return null;
        }
        if (provider.exportBindingLocalNodeSemanticIndex(binding) != sid) return error.InvalidLexicalInitializationOwner;
        if (provider.index.isNone() or provider.codegen_output_owner == .unassigned or
            !@import("../semantic/lexical_initialization.zig").validatePair(semantic.symbols.items, semantic.scopes, sid))
            return error.InvalidLexicalInitializationOwner;
        return .{
            .module = provider,
            .index = provider.index,
            .owner = provider.codegen_output_owner,
            .source_node = binding.local_symbol_node.?,
            .source = SymbolRef.makeSemantic(provider.index, sid),
            .initialized = SymbolRef.makeSemantic(provider.index, @backingInt(role.flag)),
        };
    }

    pub fn validate(plan: ReadPlan, provider: *const Module, binding: ExportBinding) error{InvalidLexicalInitializationOwner}!void {
        if (plan.module != provider or plan.index != provider.index or plan.owner != provider.codegen_output_owner or
            binding.local_symbol_node != plan.source_node) return error.InvalidLexicalInitializationOwner;
        const actual = (try fromExport(provider, binding)) orelse return error.InvalidLexicalInitializationOwner;
        if (!SymbolRef.eql(plan.source, actual.source) or !SymbolRef.eql(plan.initialized, actual.initialized))
            return error.InvalidLexicalInitializationOwner;
    }
};

/// The registry key follows an already checked Source flag identity. It never
/// selects a SymbolId and is not an export of the user's module.
pub fn registryKey(a: @import("std").mem.Allocator, provider: *const Module, symbol: @import("symbol.zig").SymbolID) ![]const u8 {
    if (provider.index.isNone() or symbol.module != provider.index or provider.codegen_output_owner == .unassigned or provider.path.len == 0)
        return error.InvalidLexicalInitializationOwner;
    const semantic = provider.semantic orelse return error.InvalidLexicalInitializationOwner;
    if (@backingInt(symbol.inner) >= semantic.symbols.items.len) return error.InvalidLexicalInitializationOwner;
    const flag = semantic.symbols.items[@backingInt(symbol.inner)];
    const source = flag.synthetic_owner_id orelse return error.InvalidLexicalInitializationOwner;
    if (flag.synthetic_kind != .lexical_initialization_flag or
        !@import("../semantic/lexical_initialization.zig").validatePair(semantic.symbols.items, semantic.scopes, @backingInt(source)) or
        semantic.symbols.items[@backingInt(source)].lexical_initialization.flag != symbol.inner) return error.InvalidLexicalInitializationOwner;
    // The helper file can be shared by independent PM builds. Graph-local
    // module numbers are not a runtime identity domain. The constructor-owned
    // resolved source path separates those providers; a length prefix keeps
    // embedded delimiters unambiguous. Canonical module renumbering is irrelevant.
    return @import("std").fmt.allocPrint(a, "{d}:{s}:{d}", .{ provider.path.len, provider.path, @backingInt(symbol.inner) });
}
