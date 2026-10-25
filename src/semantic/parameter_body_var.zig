//! Exact FunctionDeclarationInstantiation parameter-to-body-var copy roles.
const symbols_mod = @import("symbol.zig");
const Symbol = symbols_mod.Symbol;
const SymbolId = symbols_mod.SymbolId;

pub const Role = struct {
    variable: SymbolId,
    parameter: SymbolId,
    state: symbols_mod.ParameterBodyVarCopy.State,
};

pub fn forSymbol(symbols: []const Symbol, variable: SymbolId) error{InvalidParameterBodyVarRole}!?Role {
    if (variable.isNone() or @backingInt(variable) >= symbols.len) return error.InvalidParameterBodyVarRole;
    const body = symbols[@backingInt(variable)];
    const copy = body.parameter_copy;
    if (body.binding_instantiation.reserved != 0 or body.binding_instantiation.parameter_copy != !copy.parameter_source.isNone())
        return error.InvalidParameterBodyVarRole;
    if (copy.parameter_source.isNone()) {
        if (copy.state != .native) return error.InvalidParameterBodyVarRole;
        return null;
    }
    if (copy.parameter_source == variable or @backingInt(copy.parameter_source) >= symbols.len or body.kind != .variable_var)
        return error.InvalidParameterBodyVarRole;
    const parameter = symbols[@backingInt(copy.parameter_source)];
    if (parameter.kind != .parameter and (copy.state != .lowered or (parameter.kind != .variable_var and parameter.kind != .variable_let)))
        return error.InvalidParameterBodyVarRole;
    if (copy.state == .native and body.scope_id == parameter.scope_id) return error.InvalidParameterBodyVarRole;
    return .{ .variable = variable, .parameter = copy.parameter_source, .state = copy.state };
}

/// Publish after the exact V=P AST is appended. Pattern lowering may already
/// have moved P's storage into an actual body var or a native TDZ let cell.
pub fn markLowered(symbols: []Symbol, variable: SymbolId, parameter: SymbolId) error{InvalidParameterBodyVarRole}!void {
    if (variable.isNone() or parameter.isNone() or @backingInt(variable) >= symbols.len or @backingInt(parameter) >= symbols.len or variable == parameter)
        return error.InvalidParameterBodyVarRole;
    const body = &symbols[@backingInt(variable)];
    if (!body.binding_instantiation.parameter_copy or body.binding_instantiation.reserved != 0 or body.parameter_copy.parameter_source != parameter or body.kind != .variable_var or
        (symbols[@backingInt(parameter)].kind != .parameter and symbols[@backingInt(parameter)].kind != .variable_var and symbols[@backingInt(parameter)].kind != .variable_let))
        return error.InvalidParameterBodyVarRole;
    body.parameter_copy.state = .lowered;
}

pub fn validate(symbols: []const Symbol) bool {
    for (symbols, 0..) |_, index| _ = forSymbol(symbols, @fromBackingInt(@as(u32, @intCast(index)))) catch return false;
    return true;
}
