//! A legacy namespace getter expression from exact provider/helper identities.
//! The existing writer owns its zero-parameter getter wrapper. This module
//! creates no source AST, bindings, scopes, or name-based symbol lookup.
const std = @import("std");
const Module = @import("../module.zig").Module;
const ExportBinding = @import("../module.zig").ExportBinding;
const Linker = @import("../linker.zig").Linker;
const LinkingMetadata = @import("../linker.zig").LinkingMetadata;
const SymbolRef = @import("../symbol.zig").SymbolRef;
const ReadPlan = @import("../lexical_initialization_plan.zig").ReadPlan;

pub fn expression(allocator: std.mem.Allocator, linker: *const Linker, provider: *const Module, binding: ExportBinding, metadata: ?*const LinkingMetadata) !?[]const u8 {
    const plan = (try ReadPlan.fromExport(provider, binding)) orelse return null;
    try plan.validate(provider, binding);
    const builtin = try @import("../lexical_initialization_builtin.zig").exact(linker.graph);
    const foreign = SymbolRef.makeSemantic(builtin.module, @backingInt(builtin.inner));
    var helper_local: ?SymbolRef = null;
    for (provider.import_bindings) |imported| {
        if (!imported.is_helper or imported.kind != .named or !imported.symbol.eql(foreign)) continue;
        if (helper_local != null or imported.import_record_index >= provider.import_records.len or
            provider.import_records[imported.import_record_index].resolved != builtin.module)
            return error.InvalidLexicalInitializationHelperImport;
        const exact_local = provider.checkedSourceImportLocalSymbol(imported) catch return error.InvalidLexicalInitializationHelperImport;
        if (exact_local.moduleIndex() != provider.index or exact_local.semanticIndex() == null or
            !imported.local_symbol.eql(exact_local)) return error.InvalidLexicalInitializationHelperImport;
        helper_local = exact_local;
    }
    const local = helper_local orelse return error.InvalidLexicalInitializationHelperImport;
    const source_name = if (metadata) |current|
        current.renames.get(plan.source.semanticIndex().?) orelse linker.getCanonicalForExport(binding, provider.index.toU32()) orelse return error.InvalidLexicalInitializationOutputName
    else
        linker.getCanonicalForExport(binding, provider.index.toU32()) orelse return error.InvalidLexicalInitializationOutputName;
    const flag_name = try localName(linker, provider, plan.initialized, metadata);
    const helper_name = try localName(linker, provider, local, metadata);
    const semantic = provider.semantic orelse return error.InvalidLexicalInitializationOwner;
    const tree = provider.ast orelse return error.InvalidLexicalInitializationOwner;
    const raw_source_name = semantic.symbols.items[plan.source.semanticIndex().?].nameText(tree.source);
    const source_value = try @import("../../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(allocator, raw_source_name);
    defer if (source_value.ptr != raw_source_name.ptr) allocator.free(source_value);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "(");
    try out.appendSlice(allocator, flag_name);
    try out.appendSlice(allocator, ")===true?(");
    try out.appendSlice(allocator, source_name);
    try out.appendSlice(allocator, "):(");
    try out.appendSlice(allocator, helper_name);
    try out.appendSlice(allocator, ")(");
    try @import("../linker/preamble_writer.zig").appendJsStringLiteral(allocator, &out, source_value);
    try out.appendSlice(allocator, ")");
    return try out.toOwnedSlice(allocator);
}

fn localName(linker: *const Linker, provider: *const Module, reference: SymbolRef, metadata: ?*const LinkingMetadata) ![]const u8 {
    if (reference.moduleIndex() != provider.index or reference.semanticIndex() == null)
        return error.InvalidLexicalInitializationOutputName;
    const sid = reference.semanticIndex().?;
    if (metadata) |current| {
        if (current.renames.get(sid)) |name| return name;
    }
    return linker.getCanonicalByRef(reference) orelse error.InvalidLexicalInitializationOutputName;
}
