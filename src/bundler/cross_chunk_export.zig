//! The public export selects a producer carrier; lexical names never select SIDs.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const Module = @import("module.zig").Module;
const ExportBinding = @import("binding_scanner.zig").ExportBinding;
const SymbolRef = @import("symbol.zig").SymbolRef;
const Span = @import("../lexer/token.zig").Span;
const parser_module = @import("../parser/module.zig");

pub const Error = std.mem.Allocator.Error || error{InvalidCrossChunkExport};

pub fn checkedSymbol(a: std.mem.Allocator, owner: *const Module, binding: *const ExportBinding) Error!SymbolRef {
    if (owner.export_bindings.len == 0) return error.InvalidCrossChunkExport;
    const begin = @intFromPtr(owner.export_bindings.ptr);
    const address = @intFromPtr(binding);
    if (address < begin or (address - begin) % @sizeOf(ExportBinding) != 0 or
        (address - begin) / @sizeOf(ExportBinding) >= owner.export_bindings.len) return error.InvalidCrossChunkExport;
    const ast = if (owner.ast) |*value| value else return error.InvalidCrossChunkExport;
    const sem = owner.semantic orelse return error.InvalidCrossChunkExport;
    const sid = owner.exportBindingSemanticIndex(binding.*) orelse return error.InvalidCrossChunkExport;
    const source = binding.source_export_node orelse return error.InvalidCrossChunkExport;
    const statement = nodeAt(ast, source) orelse return error.InvalidCrossChunkExport;
    if (statement.tag == .export_default_declaration) {
        if (binding.kind != .local or binding.default_export_node != source or
            !std.mem.eql(u8, binding.exported_name, "default") or
            parser_module.defaultExportNeedsFacade(ast, statement.data.unary.operand, statement.data.unary.flags) != binding.has_default_export_facade) return error.InvalidCrossChunkExport;
        const anchor = if (binding.has_default_export_facade) source else binding.local_symbol_node orelse return error.InvalidCrossChunkExport;
        if (!binding.has_default_export_facade and !try declarationContains(a, ast, statement.data.unary.operand, anchor)) return error.InvalidCrossChunkExport;
        if (!attached(sem.symbol_ids, anchor, sid)) return error.InvalidCrossChunkExport;
        return binding.symbol;
    }
    if (statement.tag != .export_named_declaration or !ast.hasExtra(statement.data.extra, 4)) return error.InvalidCrossChunkExport;
    const extra = statement.data.extra;
    const declaration = ast.readExtraNode(extra, 0);
    const source_node = ast.readExtraNode(extra, 3);
    if (binding.source_declaration_node) |known| {
        if (binding.kind != .local or known != declaration or !source_node.isNone() or binding.source_specifier_node != null) return error.InvalidCrossChunkExport;
        const anchor = binding.local_symbol_node orelse return error.InvalidCrossChunkExport;
        if (!attached(sem.symbol_ids, anchor, sid) or !try declarationContains(a, ast, known, anchor) or
            !try keyMatches(a, ast, anchor, binding.exported_name)) return error.InvalidCrossChunkExport;
        return binding.symbol;
    }
    const known_specifier = binding.source_specifier_node orelse return error.InvalidCrossChunkExport;
    const specifier = nodeAt(ast, known_specifier) orelse return error.InvalidCrossChunkExport;
    const start = ast.extra_data.items[extra + 1];
    const len = ast.extra_data.items[extra + 2];
    if (!declaration.isNone() or start > ast.extra_data.items.len or len > ast.extra_data.items.len - start or
        specifier.tag != .export_specifier or specifier.data.binary.flags & parser_module.SPEC_FLAG_TYPE_ONLY != 0) return error.InvalidCrossChunkExport;
    var matches: usize = 0;
    for (ast.extra_data.items[start..][0..len]) |raw| if (raw == @backingInt(known_specifier)) {
        matches += 1;
    };
    if (matches != 1) return error.InvalidCrossChunkExport;
    const public_node = if (specifier.data.binary.right.isNone()) specifier.data.binary.left else specifier.data.binary.right;
    if (!try keyMatches(a, ast, public_node, binding.exported_name)) return error.InvalidCrossChunkExport;
    if (binding.kind == .local) {
        const anchor = binding.local_symbol_node orelse return error.InvalidCrossChunkExport;
        if (!source_node.isNone() or anchor != specifier.data.binary.left or !attached(sem.symbol_ids, anchor, sid)) return error.InvalidCrossChunkExport;
    } else {
        // This exact source re-export births a compiler-owned default bridge.
        // Its runtime SID is registered once; no source node is invented for it.
        if (binding.kind != .re_export or !binding.hasSyntheticDefault(sem.symbols.items) or
            !std.mem.eql(u8, binding.exported_name, "default")) return error.InvalidCrossChunkExport;
        const record_index = binding.import_record_index orelse return error.InvalidCrossChunkExport;
        if (record_index >= owner.import_records.len or source_node.isNone() or
            owner.import_records[record_index].source_node != source_node) return error.InvalidCrossChunkExport;
        const source_literal = nodeAt(ast, source_node) orelse return error.InvalidCrossChunkExport;
        if (source_literal.tag != .string_literal) return error.InvalidCrossChunkExport;
    }
    return binding.symbol;
}

fn nodeAt(ast: *const Ast, index: NodeIndex) ?ast_mod.Node {
    if (index.isNone() or @backingInt(index) >= ast.nodes.items.len) return null;
    return ast.getNode(index);
}

fn attached(ids: []const ?u32, index: NodeIndex, sid: u32) bool {
    return !index.isNone() and @backingInt(index) < ids.len and ids[@backingInt(index)] == sid;
}

fn declarationContains(a: std.mem.Allocator, ast: *const Ast, declaration: NodeIndex, anchor: NodeIndex) Error!bool {
    const node = nodeAt(ast, declaration) orelse return false;
    switch (node.tag) {
        .function_declaration, .class_declaration => return ast.hasExtra(node.data.extra, 1) and ast.readExtraNode(node.data.extra, 0) == anchor,
        .variable_declaration => {
            if (!ast.hasExtra(node.data.extra, 3)) return false;
            const start = ast.extra_data.items[node.data.extra + 1];
            const len = ast.extra_data.items[node.data.extra + 2];
            if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) return false;
            var matches: usize = 0;
            for (ast.extra_data.items[start..][0..len]) |raw| {
                const item = nodeAt(ast, @fromBackingInt(raw)) orelse return false;
                if (item.tag != .variable_declarator or !ast.hasExtra(item.data.extra, 1)) return false;
                var walker = try @import("../parser/ast_walk.zig").bindingIdentifiers(a, ast, ast.readExtraNode(item.data.extra, 0), .{});
                defer walker.deinit();
                while (try walker.next()) |binding| if (binding == anchor) {
                    matches += 1;
                };
            }
            return matches == 1;
        },
        else => return false,
    }
}

fn keyMatches(a: std.mem.Allocator, ast: *const Ast, index: NodeIndex, expected: []const u8) Error!bool {
    const node = nodeAt(ast, index) orelse return false;
    if (node.tag == .identifier_reference or node.tag == .binding_identifier) {
        const span = if (node.data.string_ref.start & Ast.STRING_TABLE_BIT != 0) node.data.string_ref else node.span;
        if (!validSpan(ast, span)) return false;
        return @import("../lexer/scanner.zig").Scanner.identifierValueEquals(ast.identifierNameText(node), expected);
    }
    if (node.tag != .string_literal or !validSpan(ast, node.span)) return false;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    return std.mem.eql(u8, try parser_module.moduleExportName(scratch.allocator(), ast.getText(node.span)), expected);
}

fn validSpan(ast: *const Ast, span: Span) bool {
    const table = span.start & Ast.STRING_TABLE_BIT != 0;
    if ((span.end & Ast.STRING_TABLE_BIT != 0) != table) return false;
    const start = span.start & ~Ast.STRING_TABLE_BIT;
    const end = span.end & ~Ast.STRING_TABLE_BIT;
    return start <= end and end <= (if (table) ast.string_table.items.len else ast.source.len);
}
