//! PM CJS publishes getters before dependency evaluation. The getter retains
//! the provider's actual local binding, including native lexical TDZ.
const std = @import("std");
const Module = @import("../module.zig").Module;
const Linker = @import("../linker.zig").Linker;
const EmitOptions = @import("../emitter.zig").EmitOptions;
const SymbolRef = @import("../symbol.zig").SymbolRef;

pub fn publishes(module: *const Module, options: *const EmitOptions) bool {
    if (!options.preserve_modules or options.format != .cjs or module.wrap_kind != .none) return false;
    if (options.output_exports == .named) return true;
    if (options.output_exports != .auto) return false;
    for (module.export_bindings) |binding| {
        if (!std.mem.eql(u8, binding.exported_name, "default")) return true;
    }
    return false;
}

/// Called after exact rename selection, before the first Source dependency
/// require. Runtime helper imports must already have been initialized.
pub fn append(linker: *const Linker, module: *const Module, out: *std.ArrayList(u8), allocator: std.mem.Allocator, options: *const EmitOptions, default_bridge: ?[]const u8, default_key: ?[]const u8) !void {
    const named = publishes(module, options);
    const scalar_default = options.preserve_modules and options.format == .cjs and module.wrap_kind == .none and
        (options.output_exports == .auto or options.output_exports == .default_) and module.export_bindings.len == 1 and
        std.mem.eql(u8, module.export_bindings[0].exported_name, "default");
    if (options.keep_names and options.preserve_modules and options.format == .cjs and module.wrap_kind == .none and options.output_exports != .none)
        try appendHoistedFunctionNames(linker, module, out, allocator);
    if (!named and !scalar_default) return;
    const define = if (named) try linker.esmInteropRuntimeHelperName(.def_prop) else "";
    var owned: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (owned.items) |value| linker.allocator.free(value);
        owned.deinit(linker.allocator);
    }
    const entries = (try linker.buildFinalExports(true, module.index.toU32(), module.export_bindings, &owned)) orelse return;
    defer linker.allocator.free(entries);
    for (entries) |entry| {
        // Interop materialization executes after the provider body. Keep that
        // existing bottom publication instead of evaluating it in the prefix.
        if (entry.materialize != null) continue;
        const local = entry.local;
        const binding = module.findExportBinding(entry.exported);
        const literal = entry.public_key_literal;
        const keys = @import("../public_export_key.zig");
        const key = if (literal) |value| try keys.fromLiteralSyntax(allocator, value) else try keys.fromSyntax(allocator, entry.exported);
        defer key.deinit(allocator);
        const quoted = try std.json.Stringify.valueAlloc(allocator, key.text, .{});
        defer allocator.free(quoted);
        // An anonymous default declaration is instantiated before dependencies.
        // Restore its public name before a cyclic consumer can observe it.
        if (options.keep_names) if (binding) |actual| {
            if (actual.kind == .local and actual.has_default_export_facade) if (actual.default_export_node) |source| {
                const tree = if (module.ast) |*value| value else return error.InvalidDefaultNameProducer;
                const node = tree.getNode(source);
                if (node.tag != .export_default_declaration) return error.InvalidDefaultNameProducer;
                const operand = node.data.unary.operand;
                const function = tree.getNode(operand);
                if (function.tag == .function_declaration and tree.readExtraNode(function.data.extra, @import("../../parser/ast.zig").FunctionExtra.name).isNone()) {
                    try out.print(allocator, "{s}({s},\"name\",{{value:\"default\",configurable:true}});\n", .{ try linker.esmInteropRuntimeHelperName(.def_prop), local });
                }
            };
        };
        if (scalar_default) {
            try out.print(allocator, "{s}(exports,function(){{return ", .{default_bridge orelse return error.MissingPmDefaultBridge});
        } else {
            try out.print(allocator, "{s}(exports,{s},{{enumerable:true{s},get:function(){{return ", .{ define, quoted, if (options.configurable_exports) ",configurable:true" else "" });
        }
        try appendLocalRead(linker, module, binding, local, quoted, out, allocator);
        if (scalar_default) {
            const quoted_key = try std.json.Stringify.valueAlloc(allocator, default_key orelse return error.MissingPmDefaultBridge, .{});
            defer allocator.free(quoted_key);
            try out.print(allocator, ";}},{s});\n", .{quoted_key});
        } else {
            try out.appendSlice(allocator, ";}});\n");
            try out.print(allocator, "0&&(exports[{s}]=0);\n", .{quoted});
        }
    }
}

pub fn localReadExpression(linker: *const Linker, module: *const Module, binding: @import("../module.zig").ExportBinding, local: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const keys = @import("../public_export_key.zig");
    const key = if (binding.public_key_literal) |literal| try keys.fromLiteralSyntax(allocator, literal) else try keys.fromSyntax(allocator, binding.exported_name);
    defer key.deinit(allocator);
    const quoted = try std.json.Stringify.valueAlloc(allocator, key.text, .{});
    defer allocator.free(quoted);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendLocalRead(linker, module, &binding, local, quoted, &out, allocator);
    return out.toOwnedSlice(allocator);
}

fn appendLocalRead(linker: *const Linker, module: *const Module, binding: ?*const @import("../module.zig").ExportBinding, local: []const u8, quoted: []const u8, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    if (if (binding) |actual| try @import("../lexical_initialization_plan.zig").ReadPlan.fromExport(module, actual.*) else null) |plan| {
        const flag = linker.getCanonicalByRef(plan.initialized) orelse return error.MissingLexicalInitializationOutputName;
        try @import("../graph/legacy_initialization_registry.zig").validate(linker.graph, module);
        var helper: ?[]const u8 = null;
        for (module.legacy_lexical_writes) |receipt| {
            if (@backingInt(receipt.flag) != @backingInt(plan.initialized.semantic.symbol)) continue;
            const identity = SymbolRef.makeSemantic(module.index, @backingInt(receipt.helper_local));
            var selected: ?[]const u8 = null;
            for (module.import_bindings) |imported| {
                if (!SymbolRef.eql(imported.local_symbol, identity)) continue;
                const target = imported.callsite_target orelse return error.InvalidLexicalInitializationRegistry;
                if (target.role != .tdz_helper) return error.InvalidLexicalInitializationRegistry;
                try @import("../runtime_callsite_targets.zig").validateTargetRole(linker.graph, target);
                const known = linker.graph.lexical_tdz_builtin orelse return error.InvalidLexicalInitializationBuiltin;
                if (known.module_index != target.symbol.module or known.symbol_id != target.symbol.inner or known.owner_token != target.owner)
                    return error.InvalidLexicalInitializationBuiltin;
                const published = linker.getConsumerImportTarget(target.symbol.module.toU32(), imported.imported_name) orelse return error.MissingLexicalInitializationOutputName;
                if (published.role != .binding) return error.InvalidLexicalInitializationRegistry;
                if (selected != null) return error.InvalidLexicalInitializationRegistry;
                selected = published.text;
            }
            const candidate = selected orelse return error.MissingLexicalInitializationOutputName;
            if (helper) |known| if (!std.mem.eql(u8, known, candidate)) return error.InvalidLexicalInitializationRegistry;
            helper = candidate;
        }
        try out.print(allocator, "{s}===true?{s}:{s}({s})", .{ flag, local, helper orelse return error.InvalidLexicalInitializationRegistry, quoted });
    } else {
        try out.appendSlice(allocator, local);
    }
}

pub fn appendEarlyNames(linker: *const Linker, module: *const Module, out: *std.ArrayList(u8), allocator: std.mem.Allocator, options: *const EmitOptions) !void {
    if (!options.keep_names) return;
    try appendHoistedFunctionNames(linker, module, out, allocator);
    const tree = if (module.ast) |*value| value else return;
    for (module.export_bindings) |binding| {
        if (binding.kind != .local or !binding.has_default_export_facade) continue;
        const source = binding.default_export_node orelse continue;
        const node = tree.getNode(source);
        if (node.tag != .export_default_declaration) return error.InvalidDefaultNameProducer;
        const function = tree.getNode(node.data.unary.operand);
        if (function.tag != .function_declaration or !tree.readExtraNode(function.data.extra, @import("../../parser/ast.zig").FunctionExtra.name).isNone()) continue;
        const local = linker.getCanonicalForExport(binding, module.index.toU32()) orelse return error.InvalidDefaultNameProducer;
        try out.print(allocator, "{s}({s},\"name\",{{value:\"default\",configurable:true}});\n", .{ try linker.esmInteropRuntimeHelperName(.def_prop), local });
    }
}

fn appendHoistedFunctionNames(linker: *const Linker, module: *const Module, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const tree = if (module.ast) |*value| value else return;
    const semantic = module.semantic orelse return;
    if (tree.nodes.items.len == 0) return error.InvalidDefaultNameProducer;
    // The retained parse AST has no transformed_root. Parser.parse and the
    // first analyzer use its final node as the Source program root.
    const root = tree.transformed_root orelse @as(@import("../../parser/ast.zig").NodeIndex, @fromBackingInt(@as(u32, @intCast(tree.nodes.items.len - 1))));
    const program = tree.getNode(root);
    if (program.tag != .program) return error.InvalidDefaultNameProducer;
    for (tree.extra_data.items[program.data.list.start..][0..program.data.list.len]) |raw| {
        var node = tree.getNode(@fromBackingInt(raw));
        switch (node.tag) {
            .export_named_declaration => {
                const declaration = @import("../../parser/module.zig").readExportNamedExtras(tree, node.data.extra).decl;
                if (declaration.isNone()) continue;
                node = tree.getNode(declaration);
            },
            .export_default_declaration => node = tree.getNode(node.data.unary.operand),
            else => {},
        }
        if (node.tag != .function_declaration) continue;
        const name = tree.readExtraNode(node.data.extra, @import("../../parser/ast.zig").FunctionExtra.name);
        if (name.isNone()) continue; // Anonymous default has its explicit default role above.
        const raw_name = @backingInt(name);
        if (raw_name >= semantic.symbol_ids.len) return error.InvalidDefaultNameProducer;
        const sid = semantic.symbol_ids[raw_name] orelse return error.InvalidDefaultNameProducer;
        if (sid >= semantic.symbols.items.len or !semantic.symbols.items[sid].decl_flags.is_function) return error.InvalidDefaultNameProducer;
        const original = tree.getText(tree.getNode(name).data.string_ref);
        // The rename table contains changes only. The exact declaration node
        // still owns the emitted spelling when this Source binding is unchanged.
        const selected = linker.getCanonicalByRef(SymbolRef.makeSemantic(module.index, sid)) orelse original;
        const decoded = try @import("../../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(allocator, original);
        defer if (decoded.ptr != original.ptr) allocator.free(decoded);
        if (std.mem.eql(u8, decoded, selected)) continue;
        const quoted = try std.json.Stringify.valueAlloc(allocator, decoded, .{});
        defer allocator.free(quoted);
        try out.print(allocator, "{s}({s},\"name\",{{value:{s},configurable:true}});\n", .{ try linker.esmInteropRuntimeHelperName(.def_prop), selected, quoted });
    }
}
