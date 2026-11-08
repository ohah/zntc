//! Native environment getters read actual lexical storage; re-exports read the
//! selected provider namespace without introducing an initializer call.
const std = @import("std");
const Module = @import("../module.zig").Module;
const Linker = @import("../linker.zig").Linker;
const Codegen = @import("../../codegen/codegen.zig").Codegen;
const Imports = @import("../../codegen/native_module_import_projection.zig").Context;

pub fn identifier(a: std.mem.Allocator, codegen: *Codegen, name: []const u8) ![]const u8 {
    var printer = Codegen.init(a, codegen.ast);
    defer printer.deinit();
    try printer.writeIdentifierText(name);
    return a.dupe(u8, printer.buf.items);
}
pub fn keyValue(a: std.mem.Allocator, key: []const u8) ![]const u8 {
    return if (@import("../linker/preamble_writer.zig").isQuotedName(key))
        try @import("../../string_escape.zig").decodeJsStringLiteral(a, key)
    else
        try @import("../../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(a, key);
}
pub fn append(body: *std.ArrayList(u8), a: std.mem.Allocator, module: *const Module, linker: *const Linker, codegen: *Codegen, imports: *const Imports, namespace: []const u8, provider: []const u8, bindings: []const u8) !void {
    try body.appendSlice(a, namespace);
    try body.append(a, '=');
    try body.appendSlice(a, provider);
    try body.append(a, '(');
    try body.appendSlice(a, bindings);
    try body.appendSlice(a, "={__proto__:null");
    for (module.export_bindings) |binding| {
        if (binding.kind == .re_export_star or binding.kind == .re_export_namespace) return error.InvalidNativeAsyncModuleOwner;
        const canonical = linker.resolveExportChain(module.index, binding.exported_name, 0) orelse return error.InvalidNativeAsyncModuleOwner;
        if (canonical.synthetic_member != null) return error.InvalidNativeAsyncModuleOwner;
        const key = try std.json.Stringify.valueAlloc(a, try keyValue(a, binding.exported_name), .{});
        const expression = if (canonical.module_index != module.index) other: {
            const target = linker.graph.getModule(canonical.module_index) orelse return error.InvalidNativeAsyncModuleOwner;
            if (!@import("../native_async_module_plan.zig").contains(linker.graph, target)) return error.InvalidNativeAsyncModuleOwner;
            const object = try target.allocExportsName(a, &linker.rename_table);
            const access = try @import("../linker/preamble_writer.zig").allocMemberAccess(a, canonical.export_name);
            break :other try std.fmt.allocPrint(a, "{s}{s}", .{ object, access });
        } else local: {
            if (module.exportBindingSemanticIndex(binding)) |sid| {
                if (try imports.readExpressionForSymbol(a, sid)) |read| break :local read;
                const semantic = module.semantic orelse return error.InvalidNativeAsyncModuleOwner;
                if (sid >= semantic.symbols.items.len) return error.InvalidNativeAsyncModuleOwner;
                const name = codegen.finalSymbolName(sid) orelse semantic.symbols.items[sid].nameText(module.source);
                break :local try identifier(a, codegen, name);
            }
            const name = linker.getCanonicalForExport(binding, module.index.toU32()) orelse return error.InvalidNativeAsyncModuleOwner;
            break :local try identifier(a, codegen, name);
        };
        try body.appendSlice(a, ",[");
        try body.appendSlice(a, key);
        try body.appendSlice(a, "]:()=>");
        try body.appendSlice(a, expression);
    }
    try body.appendSlice(a, "});\n");
}
