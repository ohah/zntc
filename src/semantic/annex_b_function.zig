//! Exact initial Annex B binding roles. Equal spellings never select a binding.
const ast_mod = @import("../parser/ast.zig");
const symbol_mod = @import("symbol.zig");
const Symbol = symbol_mod.Symbol;
const SymbolId = symbol_mod.SymbolId;

pub const Role = struct {
    lexical: SymbolId,
    variable: SymbolId,
    state: symbol_mod.AnnexBFunctionAlias.State,
    source_assignment_count: u32,
};

pub fn forSymbol(symbols: []const Symbol, lexical: SymbolId) error{InvalidAnnexBRole}!?Role {
    if (lexical.isNone() or @backingInt(lexical) >= symbols.len) return error.InvalidAnnexBRole;
    const source = symbols[@backingInt(lexical)];
    const alias = source.annex_b_alias;
    if (alias.variable.isNone()) {
        if (alias.state != .native or alias.source_assignment_count != 0) return error.InvalidAnnexBRole;
        return null;
    }
    if (alias.source_assignment_count == 0) return error.InvalidAnnexBRole;
    if (alias.variable == lexical or @backingInt(alias.variable) >= symbols.len) return error.InvalidAnnexBRole;
    const variable = symbols[@backingInt(alias.variable)];
    if (variable.kind != .variable_var and variable.kind != .function_decl) return error.InvalidAnnexBRole;
    if (!variable.parameter_copy.parameter_source.isNone()) return error.InvalidAnnexBRole;
    if (source.kind != .function_decl and (alias.state != .lowered or source.kind != .variable_var)) return error.InvalidAnnexBRole;
    if (alias.state != .lowered and source.scope_id == variable.scope_id) return error.InvalidAnnexBRole;
    return .{ .lexical = lexical, .variable = alias.variable, .state = alias.state, .source_assignment_count = alias.source_assignment_count };
}

pub fn forDeclaration(ast: *const ast_mod.Ast, symbol_ids: []const ?u32, symbols: []const Symbol, declaration: ast_mod.NodeIndex) error{InvalidAnnexBRole}!?Role {
    if (declaration.isNone() or @backingInt(declaration) >= ast.nodes.items.len) return error.InvalidAnnexBRole;
    const node = ast.getNode(declaration);
    if (node.tag != .function_declaration) return error.InvalidAnnexBRole;
    const name = ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
    if (name.isNone() or @backingInt(name) >= symbol_ids.len) return error.InvalidAnnexBRole;
    const lexical = symbol_ids[@backingInt(name)] orelse return error.InvalidAnnexBRole;
    return forSymbol(symbols, @fromBackingInt(lexical));
}

/// Call before relocating the lexical binding into generated var storage.
/// The assignment target remains available after native spelling affinity ends.
pub fn markLowered(symbols: []Symbol, lexical: SymbolId, source_assignment_count: u32) error{InvalidAnnexBRole}!Role {
    var role = (try forSymbol(symbols, lexical)) orelse return error.InvalidAnnexBRole;
    if (source_assignment_count != role.source_assignment_count) return error.InvalidAnnexBRole;
    if (role.state == .lowered) return role;
    const variable = @backingInt(role.variable);
    const local = @backingInt(lexical);
    if (symbols[local].reference_count < source_assignment_count or symbols[variable].reference_count < source_assignment_count or
        symbols[variable].write_count < source_assignment_count) return error.InvalidAnnexBRole;
    symbols[local].reference_count -= source_assignment_count;
    symbols[variable].reference_count -= source_assignment_count;
    symbols[variable].write_count -= source_assignment_count;
    symbols[local].annex_b_alias.state = .lowered;
    role.state = .lowered;
    return role;
}

pub fn validate(symbols: []const Symbol) bool {
    for (symbols, 0..) |_, index| _ = forSymbol(symbols, @fromBackingInt(@as(u32, @intCast(index)))) catch return false;
    return true;
}

/// Native syntax supplies the implicit alias assignment. Freeze only this exact
/// binding group so independent renamers cannot give its members different names.
/// A lowering producer clears this policy before moving the lexical storage.
pub fn nativeBindingMask(allocator: @import("std").mem.Allocator, symbols: []const Symbol) !@import("std").DynamicBitSet {
    var mask = try @import("std").DynamicBitSet.initEmpty(allocator, symbols.len);
    errdefer mask.deinit();
    for (symbols, 0..) |_, index| {
        const role = (try forSymbol(symbols, @fromBackingInt(@as(u32, @intCast(index))))) orelse continue;
        if (role.state == .lowered) continue;
        mask.set(@backingInt(role.lexical));
        mask.set(@backingInt(role.variable));
    }
    return mask;
}
