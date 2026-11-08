//! Exact ownership of private initialization state for lowered module lexicals.
const symbol = @import("symbol.zig");
const Symbol = symbol.Symbol;
const Scope = @import("scope.zig").Scope;

pub fn validatePair(symbols: []const Symbol, scopes: []const Scope, source: u32) bool {
    if (source >= symbols.len) return false;
    const owner = symbols[source];
    const role = owner.lexical_initialization;
    if (role.state == .native) return role.flag.isNone() and !owner.binding_instantiation.lexical_initialization;
    if (!owner.binding_instantiation.lexical_initialization or role.flag.isNone()) return false;
    const flag_raw = @backingInt(role.flag);
    if (flag_raw >= symbols.len or flag_raw == source) return false;
    if (owner.kind != .variable_let and owner.kind != .variable_const and owner.kind != .class_decl) return false;
    if (owner.scope_id.isNone() or owner.scope_id.toIndex() >= scopes.len) return false;
    const scope = scopes[owner.scope_id.toIndex()];
    if ((scope.kind != .global and scope.kind != .module) or !scope.parent.isNone()) return false;
    const flag = symbols[flag_raw];
    return flag.kind == .variable_var and flag.synthetic_kind == .lexical_initialization_flag and
        flag.synthetic_owner_id != null and @backingInt(flag.synthetic_owner_id.?) == source and
        flag.scope_id == owner.scope_id and !flag.isExported() and
        flag.lexical_initialization.state == .native and flag.lexical_initialization.flag.isNone() and
        !flag.binding_instantiation.lexical_initialization;
}

/// The cache checks both directions, including orphaned private flags. The
/// publication hot path checks only its already selected pair in constant time.
pub fn validate(symbols: []const Symbol, scopes: []const Scope) bool {
    for (symbols, 0..) |owner, raw| {
        if (!validatePair(symbols, scopes, @intCast(raw))) return false;
        if (owner.synthetic_kind == .lexical_initialization_flag) {
            const source = owner.synthetic_owner_id orelse return false;
            const source_raw = @backingInt(source);
            if (source_raw >= symbols.len or source_raw == raw) return false;
            const source_role = symbols[source_raw].lexical_initialization;
            if (source_role.state != .lowered_module or @backingInt(source_role.flag) != raw or
                !validatePair(symbols, scopes, source_raw)) return false;
        }
    }
    return true;
}
