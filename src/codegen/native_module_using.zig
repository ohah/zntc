//! Source-owned direct program using declarations in a compiler-owned module shell.
//! Selection uses physical root edges and first-analysis identities, never names.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Wrapper = @import("../bundler/native_module_wrapper_program.zig").Program;
const Local = @import("../bundler/compiler_output_program.zig").Local;
const NodeIndex = ast.NodeIndex;
const Error = error{InvalidNativeModuleUsingContext};
const semantic = @import("../semantic/symbol.zig");
pub const SourceView = struct {
    domain: *const ast.Ast,
    symbol_ids: []const ?u32,
    symbols: []const semantic.Symbol,
    scopes: []const @import("../semantic/scope.zig").Scope,
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    references: []const semantic.Reference,
    pub fn fromAnalyzer(analysis: *const Analyzer) SourceView {
        return .{ .domain = analysis.ast, .symbol_ids = analysis.symbol_ids.items, .symbols = analysis.symbols.items, .scopes = analysis.scopes.items, .scope_owner_map = &analysis.scope_owner_map, .references = analysis.references.items };
    }
};

pub const Binding = struct { declarator: NodeIndex, binding: NodeIndex, initializer: NodeIndex, symbol: u32 };
pub const Declaration = struct { statement: NodeIndex, declaration: NodeIndex, snapshot: ast.Node, bindings: []const Binding };
pub const Context = struct {
    domain: *const ast.Ast,
    root: NodeIndex,
    analysis: SourceView,
    wrapper: *const Wrapper,
    environment: Local,
    stack: Local,
    declarations: []const Declaration,
    source: []const u8,
    source_hash: u64,

    /// Allocations belong to the caller's arena; all source/compiler objects are borrowed.
    pub fn create(a: std.mem.Allocator, domain: *const ast.Ast, root: NodeIndex, analysis: SourceView, wrapper: *const Wrapper) !Context {
        wrapper.validate() catch return error.InvalidNativeModuleUsingContext;
        if (analysis.domain != domain or root.isNone() or @backingInt(root) >= domain.nodes.items.len or domain.getNode(root).tag != .program)
            return error.InvalidNativeModuleUsingContext;
        var declarations: std.ArrayListUnmanaged(Declaration) = .empty;
        const program = domain.getNode(root);
        if (program.data.list.start > domain.extra_data.items.len or program.data.list.len > domain.extra_data.items.len - program.data.list.start) return error.InvalidNativeModuleUsingContext;
        for (domain.extra_data.items[program.data.list.start..][0..program.data.list.len]) |raw| {
            const statement: NodeIndex = @fromBackingInt(raw);
            const declaration = directDeclaration(domain, statement);
            if (declaration.isNone()) continue;
            const node = domain.getNode(declaration);
            if (!domain.variableDeclarationKind(node).isUsing()) continue;
            if (!domain.hasExtra(node.data.extra, 2)) return error.InvalidNativeModuleUsingContext;
            const extra = domain.extra_data.items[node.data.extra..][0..3];
            if (extra[1] > domain.extra_data.items.len or extra[2] > domain.extra_data.items.len - extra[1]) return error.InvalidNativeModuleUsingContext;
            const bindings = try a.alloc(Binding, extra[2]);
            for (domain.extra_data.items[extra[1]..][0..extra[2]], 0..) |decl_raw, i| {
                if (decl_raw >= domain.nodes.items.len) return error.InvalidNativeModuleUsingContext;
                const decl = domain.nodes.items[decl_raw];
                if (decl.tag != .variable_declarator or !domain.hasExtra(decl.data.extra, 2)) return error.InvalidNativeModuleUsingContext;
                const edges = domain.extra_data.items[decl.data.extra..][0..3];
                const binding: NodeIndex = @fromBackingInt(edges[0]);
                const initializer: NodeIndex = @fromBackingInt(edges[2]);
                if (binding.isNone() or initializer.isNone() or @backingInt(binding) >= domain.nodes.items.len or @backingInt(initializer) >= domain.nodes.items.len or domain.getNode(binding).tag != .binding_identifier or @backingInt(binding) >= analysis.symbol_ids.len)
                    return error.InvalidNativeModuleUsingContext;
                bindings[i] = .{ .declarator = @fromBackingInt(decl_raw), .binding = binding, .initializer = initializer, .symbol = analysis.symbol_ids[@backingInt(binding)] orelse return error.InvalidNativeModuleUsingContext };
            }
            try declarations.append(a, .{ .statement = statement, .declaration = declaration, .snapshot = node, .bindings = bindings });
        }
        const self: Context = .{ .domain = domain, .root = root, .analysis = analysis, .wrapper = wrapper, .environment = try wrapper.environmentLocal(), .stack = try wrapper.stackLocal(), .declarations = try declarations.toOwnedSlice(a), .source = domain.source, .source_hash = std.hash.Wyhash.hash(0, domain.source) };
        try self.validate(domain);
        return self;
    }

    pub fn validate(self: *const Context, domain: *const ast.Ast) Error!void {
        if (domain != self.domain or self.analysis.domain != domain or self.source.ptr != domain.source.ptr or self.source.len != domain.source.len or self.source_hash != std.hash.Wyhash.hash(0, domain.source) or self.root.isNone() or @backingInt(self.root) >= domain.nodes.items.len)
            return error.InvalidNativeModuleUsingContext;
        self.wrapper.validate() catch return error.InvalidNativeModuleUsingContext;
        if (!std.meta.eql(self.environment, self.wrapper.environmentLocal() catch return error.InvalidNativeModuleUsingContext) or !std.meta.eql(self.stack, self.wrapper.stackLocal() catch return error.InvalidNativeModuleUsingContext)) return error.InvalidNativeModuleUsingContext;
        const program = domain.getNode(self.root);
        if (program.tag != .program or program.data.list.start > domain.extra_data.items.len or program.data.list.len > domain.extra_data.items.len - program.data.list.start) return error.InvalidNativeModuleUsingContext;
        for (self.declarations) |declaration| {
            var member = false;
            for (domain.extra_data.items[program.data.list.start..][0..program.data.list.len]) |raw| if (raw == @backingInt(declaration.statement)) {
                member = true;
            };
            if (!member or directDeclaration(domain, declaration.statement) != declaration.declaration or @backingInt(declaration.declaration) >= domain.nodes.items.len) return error.InvalidNativeModuleUsingContext;
            const node = domain.getNode(declaration.declaration);
            if ((node.tag != declaration.snapshot.tag or !std.meta.eql(node.span, declaration.snapshot.span) or node.data.extra != declaration.snapshot.data.extra) or !domain.variableDeclarationKind(node).isUsing()) return error.InvalidNativeModuleUsingContext;
            if (!domain.hasExtra(node.data.extra, 2)) return error.InvalidNativeModuleUsingContext;
            const extra = domain.extra_data.items[node.data.extra..][0..3];
            if (extra[1] > domain.extra_data.items.len or extra[2] > domain.extra_data.items.len - extra[1]) return error.InvalidNativeModuleUsingContext;
            if (extra[2] != declaration.bindings.len) return error.InvalidNativeModuleUsingContext;
            for (declaration.bindings, 0..) |binding, i| {
                if (binding.binding.isNone() or binding.initializer.isNone() or binding.declarator.isNone() or @backingInt(binding.binding) >= domain.nodes.items.len or @backingInt(binding.initializer) >= domain.nodes.items.len or @backingInt(binding.declarator) >= domain.nodes.items.len) return error.InvalidNativeModuleUsingContext;
                if (domain.extra_data.items[extra[1] + i] != @backingInt(binding.declarator) or binding.symbol >= self.analysis.symbols.len or @backingInt(binding.binding) >= self.analysis.symbol_ids.len or self.analysis.symbol_ids[@backingInt(binding.binding)] != binding.symbol) return error.InvalidNativeModuleUsingContext;
                const declarator = domain.getNode(binding.declarator);
                if (declarator.tag != .variable_declarator or !domain.hasExtra(declarator.data.extra, 2)) return error.InvalidNativeModuleUsingContext;
                const edges = domain.extra_data.items[declarator.data.extra..][0..3];
                if (edges[0] != @backingInt(binding.binding) or edges[2] != @backingInt(binding.initializer) or domain.getNode(binding.binding).tag != .binding_identifier) return error.InvalidNativeModuleUsingContext;
                const symbol = self.analysis.symbols[binding.symbol];
                const source_scope = self.analysis.scope_owner_map.get(@backingInt(self.root)) orelse return error.InvalidNativeModuleUsingContext;
                if (source_scope >= self.analysis.scopes.len or (self.analysis.scopes[source_scope].kind != .module and self.analysis.scopes[source_scope].kind != .global)) return error.InvalidNativeModuleUsingContext;
                var anchors: usize = 0;
                for (self.analysis.references) |reference| {
                    if (reference.symbol_id == @as(@import("../semantic/symbol.zig").SymbolId, @fromBackingInt(binding.symbol)) and @backingInt(reference.scope_id) == source_scope and reference.declaration_node_index == binding.binding and reference.node_index.isNone() and reference.flags.declare) anchors += 1;
                }
                if (anchors != 1) return error.InvalidNativeModuleUsingContext;
                if (symbol.kind != .variable_var or @backingInt(symbol.scope_id) != source_scope or symbol.origin_scope != symbol.scope_id) return error.InvalidNativeModuleUsingContext;
            }
        }
    }
};

fn directDeclaration(domain: *const ast.Ast, statement: NodeIndex) NodeIndex {
    if (statement.isNone() or @backingInt(statement) >= domain.nodes.items.len) return .none;
    const node = domain.getNode(statement);
    if (node.tag == .variable_declaration) return statement;
    if (node.tag == .export_named_declaration) {
        if (!domain.hasExtra(node.data.extra, 0)) return .none;
        const declaration = @import("../parser/module.zig").readExportNamedExtras(domain, node.data.extra).decl;
        if (!declaration.isNone() and @backingInt(declaration) < domain.nodes.items.len and domain.getNode(declaration).tag == .variable_declaration) return declaration;
    }
    return .none;
}

pub fn emit(self: anytype, index: NodeIndex) @import("codegen.zig").Codegen.Error!bool {
    if (!self.options.module_await_as_yield) return false;
    const context = self.options.native_module_using orelse return false;
    if (context.domain != self.ast) return error.InvalidNativeModuleUsingContext;
    for (context.declarations) |declaration| {
        if (declaration.declaration != index) continue;
        try context.validate(self.ast);
        try self.write("const ");
        for (declaration.bindings, 0..) |binding, i| {
            if (self.sourceSymbolId(binding.binding) != binding.symbol) return error.InvalidNativeModuleUsingContext;
            if (i != 0) try self.writeByte(',');
            try self.emitNode(binding.binding);
            try self.writeByte('=');
            try self.write(context.environment.final_name);
            try self.write("[0](");
            try self.write(context.stack.final_name);
            try self.writeByte(',');
            const anonymous = self.ast.isAnonymousFunctionDefinition(binding.initializer);
            // Computed own-property NamedEvaluation needs no global Object and
            // keeps __proto__ an ordinary key. The analyzed binding supplies
            // the source reflection name, never an identity lookup.
            const name = self.ast.getText(self.ast.getNode(binding.binding).data.string_ref);
            if (anonymous) {
                try self.write("({[");
                try @import("keep_names.zig").writeQuoted(self, name);
                try self.write("]:");
            }
            try self.emitExpr(binding.initializer, .comma, .{});
            if (anonymous) {
                try self.write("})[");
                try @import("keep_names.zig").writeQuoted(self, name);
                try self.writeByte(']');
            }
            try self.write(if (self.ast.variableDeclarationKind(declaration.snapshot) == .await_using) ",true)" else ",false)");
        }
        try self.writeByte(';');
        return true;
    }
    return false;
}
