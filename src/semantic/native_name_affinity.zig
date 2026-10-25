//! Source syntax supplies implicit assignments only for these exact groups.
const std = @import("std");
const Symbol = @import("symbol.zig").Symbol;
const SymbolId = @import("symbol.zig").SymbolId;
const annex = @import("annex_b_function.zig");
const parameters = @import("parameter_body_var.zig");

pub fn bindingMask(allocator: std.mem.Allocator, symbols: []const Symbol) !std.DynamicBitSet {
    var mask = try std.DynamicBitSet.initEmpty(allocator, symbols.len);
    errdefer mask.deinit();
    for (symbols, 0..) |_, index| {
        const id: SymbolId = @fromBackingInt(@as(u32, @intCast(index)));
        if (try annex.forSymbol(symbols, id)) |role| if (role.state == .native) {
            mask.set(index);
            mask.set(@backingInt(role.variable));
        };
        if (try parameters.forSymbol(symbols, id)) |role| if (role.state == .native) {
            mask.set(index);
            mask.set(@backingInt(role.parameter));
        };
    }
    return mask;
}

/// This selects an output spelling representative, never a binding identity.
pub fn representative(symbols: []const Symbol, identity: SymbolId) !SymbolId {
    var result = identity;
    if (try annex.forSymbol(symbols, result)) |role| if (role.state == .native) {
        result = role.variable;
    };
    if (try parameters.forSymbol(symbols, result)) |role| if (role.state == .native) {
        result = role.parameter;
    };
    return result;
}
