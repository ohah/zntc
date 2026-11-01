//! Completed authority for scalar public assignment fields in native legacy classes.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const NodeIndex = ast_mod.NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const module_mod = @import("../bundler/module.zig");
const Options = @import("transformer.zig").TransformOptions;

pub const Field = struct {
    node: NodeIndex,
    class: NodeIndex,
    class_scope: ScopeId,
    outer_scope: ScopeId,
    symbol: u32,
    key: NodeIndex,
    value: NodeIndex,
    is_static: bool,
};
/// Entries borrow source nodes and the caller's arena; no source AST is owned.
pub const Source = struct {
    ast: *const ast_mod.Ast,
    owner: module_mod.SemanticOwnerToken,
    fields: []const Field,
};
pub const Applied = struct {
    field: NodeIndex,
    statement: NodeIndex,
    object: NodeIndex,
    key: NodeIndex,
    value: NodeIndex,
    scope: ScopeId,
    initializer_function: NodeIndex = .none,
    initializer_params: NodeIndex = .none,
    initializer_body: NodeIndex = .none,
    initializer_scope: ScopeId = .none,
};

fn scalar(tag: ast_mod.Node.Tag) bool {
    return switch (tag) {
        .numeric_literal, .string_literal, .boolean_literal, .null_literal => true,
        else => false,
    };
}

pub fn sourcePlan(a: std.mem.Allocator, ast: *const ast_mod.Ast, sem: *const module_mod.ModuleSemanticData, options: Options) !?Source {
    if (!options.experimental_decorators or !options.strip_types or options.minify_syntax or
        options.unsupported.class or !ast.has_decorator or sem.scopes.len == 0 or sem.scopes[0].blocksMangling()) return null;
    const reachable = try walk.collectReachableNodeIndices(a, ast);
    defer a.free(reachable);
    var fields: std.ArrayList(Field) = .empty;
    defer fields.deinit(a);
    const Declaration = struct { symbol: u32, scope: ScopeId, count: usize = 1, valid: bool };
    var declarations: std.AutoHashMapUnmanaged(u32, Declaration) = .empty;
    defer declarations.deinit(a);
    for (sem.references) |row| {
        if (!row.flags.declare or row.declaration_node_index.isNone()) continue;
        const entry = try declarations.getOrPut(a, @backingInt(row.declaration_node_index));
        if (entry.found_existing) {
            entry.value_ptr.count += 1;
        } else {
            entry.value_ptr.* = .{ .symbol = @backingInt(row.symbol_id), .scope = row.scope_id, .valid = row.node_index.isNone() and std.meta.eql(row.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .declare = true })) };
        }
    }
    var observed: usize = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag == .static_block or node.tag == .private_identifier or node.tag == .with_statement) return null;
        if (node.tag == .property_definition) observed += 1;
        if (node.tag != .class_declaration and node.tag != .class_expression) continue;
        const class: NodeIndex = @fromBackingInt(raw);
        const body = ast.readExtraNode(node.data.extra, ast_mod.ClassExtra.body);
        if (body.isNone() or ast.getNode(body).tag != .class_body) return null;
        const members = ast.getNode(body).data.list;
        for (ast.extra_data.items[members.start .. members.start + members.len]) |member_raw| {
            const member = ast.nodes.items[member_raw];
            if (member.tag != .property_definition) continue;
            // No derived-field placement or anonymous class-name authority in
            // this native scalar family. Other classes without fields are unchanged.
            if (node.tag != .class_declaration or !ast.readExtraNode(node.data.extra, ast_mod.ClassExtra.super).isNone()) return null;
            const owner_raw = sem.scope_owner_map.get(raw) orelse return null;
            if (owner_raw >= sem.scopes.len or sem.scopes[owner_raw].kind != .class_body) return null;
            const owner: ScopeId = @fromBackingInt(owner_raw);
            const outer = sem.scopes[owner_raw].parent;
            if (outer.isNone() or outer.toIndex() >= sem.scopes.len) return null;
            const name = ast.readExtraNode(node.data.extra, ast_mod.ClassExtra.name);
            if (name.isNone() or @backingInt(name) >= sem.symbol_ids.len or ast.getNode(name).tag != .binding_identifier) return null;
            const sid = sem.symbol_ids[@backingInt(name)] orelse return null;
            if (sid >= sem.symbols.items.len or sem.symbols.items[sid].scope_id != outer or sem.symbols.items[sid].kind != .class_decl or (sem.symbols.items[sid].synthetic_kind != null or sem.symbols.items[sid].synthetic_name.len != 0)) return null;
            const declaration = declarations.get(@backingInt(name)) orelse return null;
            if (!declaration.valid or declaration.count != 1 or declaration.symbol != sid or declaration.scope != outer) return null;
            const flags = ast.readExtra(member.data.extra, ast_mod.PropertyExtra.flags);
            if (flags & ~@as(u32, ast_mod.PropertyFlags.is_static) != 0) return null;
            const key = ast.readExtraNode(member.data.extra, ast_mod.PropertyExtra.key);
            const value = ast.readExtraNode(member.data.extra, ast_mod.PropertyExtra.init);
            if (key.isNone() or value.isNone() or ast.getNode(key).tag != .identifier_reference or !scalar(ast.getNode(value).tag)) return null;
            try fields.append(a, .{ .node = @fromBackingInt(member_raw), .class = class, .class_scope = owner, .outer_scope = outer, .symbol = sid, .key = key, .value = value, .is_static = flags & ast_mod.PropertyFlags.is_static != 0 });
        }
    }
    if (fields.items.len == 0 or fields.items.len != observed) return null;
    return .{ .ast = ast, .owner = sem.owner_token, .fields = try fields.toOwnedSlice(a) };
}

pub fn record(self: anytype, field: NodeIndex, statement: NodeIndex, object: NodeIndex, key: NodeIndex, value: NodeIndex, scope: ScopeId) !void {
    if (self.legacy_assignment_field_source == null or field.isNone()) return;
    var applied: Applied = .{ .field = field, .statement = statement, .object = object, .key = key, .value = value, .scope = scope };
    if (self.ast.getNode(value).tag == .call_expression) {
        const callee = self.ast.readExtraNode(self.ast.getNode(value).data.extra, 0);
        if (!callee.isNone() and self.ast.getNode(callee).tag == .function_expression) {
            applied.initializer_function = callee;
            applied.initializer_params = self.ast.readExtraNode(self.ast.getNode(callee).data.extra, ast_mod.FunctionExtra.params);
            applied.initializer_body = self.ast.readExtraNode(self.ast.getNode(callee).data.extra, ast_mod.FunctionExtra.body);
            applied.initializer_scope = self.outputOwnedScope(callee) orelse .none;
        }
    }
    try self.legacy_assignment_field_applications.append(self.allocator, applied);
}

/// Prove the producer's concrete output before publishing positions. No SID,
/// Scope, declaration or reference flags are repaired here.
fn staticScalar(ast: *const ast_mod.Ast, sem: *const module_mod.ModuleSemanticData, output: Applied, outer: ScopeId) ?NodeIndex {
    const node = ast.getNode(output.value);
    if (node.tag != .call_expression or ast.readExtra(node.data.extra, 2) != 0 or ast.readExtra(node.data.extra, 3) != 0) return null;
    const callee = ast.readExtraNode(node.data.extra, 0);
    if (callee != output.initializer_function or callee.isNone() or ast.getNode(callee).tag != .function_expression) return null;
    const function = ast.getNode(callee);
    if (!ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.name).isNone() or ast.readExtra(function.data.extra, ast_mod.FunctionExtra.flags) != 0) return null;
    const owner = sem.scope_owner_map.get(@backingInt(callee)) orelse return null;
    if (output.initializer_scope.isNone() or owner != @backingInt(output.initializer_scope) or owner >= sem.scopes.len or sem.scopes[owner].kind != .function or sem.scopes[owner].parent != outer or !sem.scopes[owner].is_strict) return null;
    const params = ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.params);
    const body = ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.body);
    if (params != output.initializer_params or body != output.initializer_body or params.isNone() or body.isNone() or ast.getNode(params).tag != .formal_parameters or ast.getNode(params).data.list.len != 0 or ast.getNode(body).tag != .block_statement) return null;
    const statements = ast.getNode(body).data.list;
    if (statements.len != 2) return null;
    const directive: NodeIndex = @fromBackingInt(ast.extra_data.items[statements.start]);
    const result: NodeIndex = @fromBackingInt(ast.extra_data.items[statements.start + 1]);
    const directive_node = ast.getNode(directive);
    if (directive_node.tag != .directive or ast.getNode(result).tag != .return_statement) return null;
    const text = ast.getText(directive_node.span);
    if (!std.mem.eql(u8, text, "\"use strict\"") and !std.mem.eql(u8, text, "'use strict'")) return null;
    return ast.getNode(result).data.unary.operand;
}

pub fn complete(self: anytype, sem: *module_mod.ModuleSemanticData, root: NodeIndex) !bool {
    const source = self.legacy_assignment_field_source orelse return false;
    if (source.owner == .unassigned or source.owner != sem.owner_token or source.ast != self.semantic_source_ast or
        source.fields.len == 0 or source.fields.len != self.legacy_assignment_field_applications.items.len) return false;
    const ast = self.ast;
    const nodes = try walk.collectReachableNodeIndicesFrom(self.allocator, ast, root);
    defer self.allocator.free(nodes);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer live.deinit(self.allocator);
    var parents: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer parents.deinit(self.allocator);
    for (nodes) |raw| {
        try live.put(self.allocator, raw, {});
        var children = walk.children(ast, ast.nodes.items[raw]);
        while (children.next()) |child| {
            if (child.isNone()) continue;
            if (@backingInt(child) >= ast.nodes.items.len) return false;
            const entry = try parents.getOrPut(self.allocator, @backingInt(child));
            if (entry.found_existing and entry.value_ptr.* != raw) return false;
            entry.value_ptr.* = raw;
        }
    }
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    for (source.fields) |field| {
        var applied: ?Applied = null;
        for (self.legacy_assignment_field_applications.items) |candidate| {
            if (candidate.field != field.node) continue;
            if (applied != null) return false;
            applied = candidate;
        }
        const output = applied orelse return false;
        if (field.class.isNone() or @backingInt(field.class) >= ast.nodes.items.len or ast.getNode(field.class).tag != .class_declaration or
            field.class_scope.isNone() or field.class_scope.toIndex() >= sem.scopes.len or
            sem.scopes[field.class_scope.toIndex()].kind != .class_body or sem.scopes[field.class_scope.toIndex()].parent != field.outer_scope or
            field.symbol >= sem.symbols.items.len or sem.symbols.items[field.symbol].scope_id != field.outer_scope) return false;
        const source_body = ast.readExtraNode(ast.getNode(field.class).data.extra, ast_mod.ClassExtra.body);
        if (source_body.isNone() or ast.getNode(source_body).tag != .class_body) return false;
        const source_members = ast.getNode(source_body).data.list;
        var source_edges: usize = 0;
        for (ast.extra_data.items[source_members.start .. source_members.start + source_members.len]) |raw| {
            if (raw == @backingInt(field.node)) source_edges += 1;
        }
        if (source_edges != 1) return false;
        if (field.node.isNone() or @backingInt(field.node) >= ast.nodes.items.len or ast.getNode(field.node).tag != .property_definition or
            ast.readExtraNode(ast.getNode(field.node).data.extra, ast_mod.PropertyExtra.key) != field.key or
            ast.readExtraNode(ast.getNode(field.node).data.extra, ast_mod.PropertyExtra.init) != field.value or
            ast.readExtra(ast.getNode(field.node).data.extra, ast_mod.PropertyExtra.flags) != (if (field.is_static) @as(u32, ast_mod.PropertyFlags.is_static) else 0)) return false;
        if ((try seen.getOrPut(self.allocator, @backingInt(output.statement))).found_existing or
            !live.contains(@backingInt(output.statement)) or live.contains(@backingInt(field.node)) or
            output.scope.isNone() or output.scope.toIndex() >= sem.scopes.len) return false;
        const statement = ast.getNode(output.statement);
        if (statement.tag != .expression_statement) return false;
        const assignment = ast.getNode(statement.data.unary.operand);
        if (assignment.tag != .assignment_expression or assignment.data.binary.right != output.value) return false;
        const member = ast.getNode(assignment.data.binary.left);
        if (member.tag != .static_member_expression or ast.readExtraNode(member.data.extra, 0) != output.object or ast.readExtraNode(member.data.extra, 1) != output.key) return false;
        const value = if (field.is_static) staticScalar(ast, sem, output, field.outer_scope) orelse return false else output.value;
        if (value != field.value or !scalar(ast.getNode(value).tag) or
            !std.mem.eql(u8, ast.identifierNameText(ast.getNode(output.key)), ast.identifierNameText(ast.getNode(field.key)))) return false;
        var class_owner: ?NodeIndex = null;
        for (nodes) |raw| {
            const tag = ast.nodes.items[raw].tag;
            if (tag != .class_declaration and tag != .class_expression) continue;
            if (sem.scope_owner_map.get(raw) != @backingInt(field.class_scope)) continue;
            if (class_owner != null) return false;
            class_owner = @fromBackingInt(raw);
        }
        const class = class_owner orelse return false;
        if (field.is_static) {
            if (output.scope != field.outer_scope or ast.getNode(output.object).tag != .identifier_reference or
                @backingInt(output.object) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(output.object)] != field.symbol) return false;
            var rows: usize = 0;
            for (sem.references) |row| {
                if (row.node_index != output.object) continue;
                if (@backingInt(row.symbol_id) != field.symbol or row.scope_id != field.outer_scope or
                    !std.meta.eql(row.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .read = true }))) return false;
                rows += 1;
            }
            if (rows != 1) return false;
        } else {
            if (ast.getNode(output.object).tag != .this_expression or sem.scopes[output.scope.toIndex()].kind != .function or
                sem.scopes[output.scope.toIndex()].parent != field.class_scope) return false;
            var cursor = @backingInt(output.statement);
            var constructor: ?NodeIndex = null;
            while (parents.get(cursor)) |parent| {
                if (ast.nodes.items[parent].tag == .method_definition) {
                    constructor = @fromBackingInt(parent);
                    break;
                }
                cursor = parent;
            }
            const ctor = constructor orelse return false;
            if (sem.scope_owner_map.get(@backingInt(ctor)) != @backingInt(output.scope)) return false;
            const ctor_node = ast.getNode(ctor);
            const key = ast.readExtraNode(ctor_node.data.extra, ast_mod.MethodExtra.key);
            if (!std.mem.eql(u8, ast.identifierNameText(ast.getNode(key)), "constructor")) return false;
            const class_body = ast.readExtraNode(ast.getNode(class).data.extra, ast_mod.ClassExtra.body);
            if (parents.get(@backingInt(ctor)) != @backingInt(class_body)) return false;
        }
    }
    const contexts = try @import("../semantic/statement_coordinates.zig").collect(self.allocator, ast, root);
    defer self.allocator.free(contexts);
    for (self.legacy_assignment_field_applications.items) |output| {
        if (contexts[@backingInt(output.object)] == null) return false;
    }
    // All authority checks and allocations precede the positions-only writes.
    for (self.legacy_assignment_field_applications.items) |output| {
        const context = contexts[@backingInt(output.object)].?;
        for (@constCast(sem.references)) |*row| {
            if (row.node_index != output.object) continue;
            row.stmt_idx = context.stmt_idx;
            row.scope_stmt_idx = context.scope_stmt_idx;
        }
    }
    return true;
}

const RuntimeCase = struct { source: []const u8, expected: []const u8, flow: bool = false };
const decorate = "function decorate(value:any,key?:any,descriptor?:any):any{return descriptor||value;}";
const runtime_cases = [_]RuntimeCase{
    .{ .source = decorate ++ "@decorate class Example{value:number=2;}console.log(new Example().value);", .expected = "2\n" },
    .{ .source = decorate ++ "@decorate class Example{value:string='text';}console.log(new Example().value);", .expected = "text\n" },
    .{ .source = decorate ++ "@decorate class Example{value:boolean=true;}console.log(new Example().value);", .expected = "true\n" },
    .{ .source = decorate ++ "@decorate class Example{value:any=null;}console.log(new Example().value);", .expected = "null\n" },
    .{ .source = decorate ++ "@decorate class Example{static value:number=40;}console.log(Example.value);", .expected = "40\n" },
    .{ .source = decorate ++ "@decorate class Example{value:number=2;constructor(){console.log(this.value);}}new Example();", .expected = "2\n" },
    .{ .source = decorate ++ "@decorate class Example{first:number=2;second:string='next';}var x=new Example();console.log(x.first,x.second);", .expected = "2 next\n" },
    .{ .source = decorate ++ "{ @decorate class Example{value:number=3;}console.log(new Example().value); } { @decorate class Example{value:number=4;}console.log(new Example().value); }", .expected = "3\n4\n" },
    .{ .source = decorate ++ "function create(){@decorate class Example{value:number=5;}return new Example().value;}console.log(create());", .expected = "5\n" },
    .{ .source = "function wrap(target:any):any{return class extends target{static wrapped():number{return this.value+1;}};} @wrap class Box{static value:number=40;}console.log(Box.wrapped(),Object.getPrototypeOf(Box).name);", .expected = "41 Box\n", .flow = true },
    .{ .source = "const __decorateClass=7,__decorateParam=8,__metadata=9,__defProp2=10; const events:Record<string,number>={class:0,property:0,method:0,parameter:0,computed:0}; function classDec(target:any):any{events.class++;return target;} function propertyDec(target:any,key:string):void{events.property++;} function methodDec(target:any,key:string,descriptor:PropertyDescriptor):PropertyDescriptor{events.method++;const original=descriptor.value;descriptor.value=function(...args:any[]){return original.apply(this,args)+1;};return descriptor;} function parameterDec(target:any,key:string,index:number):void{events.parameter++;} function computedKey():string{events.computed++;return 'computed';} @classDec class Example{@propertyDec value:number=2; @methodDec method(@parameterDec first:number,value:number):number{return(first??0)+value+40;} @methodDec [computedKey()]():number{return 2;} static self():typeof Example{return Example;}} console.log(new Example().value,new Example().method(undefined,3),new Example().computed(),Example.self()===Example,events.class,events.property,events.method,events.parameter,events.computed,__decorateClass,__decorateParam,__metadata,__defProp2);", .expected = "2 44 3 true 1 1 2 1 1 7 8 9 10\n" },
};

test "legacy scalar assignment fields retain completed native owners and runtime order" {
    const helpers = @import("../bundler/test_helpers.zig");
    const bundler_mod = @import("../bundler/bundler.zig");
    const profile = @import("../profile.zig");
    for (runtime_cases, 0..) |case, index| {
        for ([_]@import("compat.zig").ESTarget{ .esnext, .es2022 }) |target| {
            for ([_]bool{ false, true }) |minify| {
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                const filename = if (case.flow) "entry.js" else "entry.ts";
                try helpers.writeFile(tmp.dir, filename, case.source);
                const entry = try helpers.absPath(&tmp, filename);
                defer std.testing.allocator.free(entry);
                profile.resetForTest();
                defer profile.resetForTest();
                profile.setIoForTest(std.testing.io);
                profile.addFromCsv("graph.resync.semantic");
                var bundler = bundler_mod.Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .experimental_decorators = true, .flow = case.flow, .unsupported = @import("compat.zig").fromESTarget(target), .minify_identifiers = minify });
                defer bundler.deinit();
                const result = try bundler.bundle(std.testing.io);
                defer result.deinit(std.testing.allocator);
                try std.testing.expect(!result.hasErrors());
                // Both source and virtual provider retain their producer graph.
                const provider_resyncs: u32 = 0;
                if (profile.count(.graph_resync_semantic) != provider_resyncs) std.debug.print("legacy field certificate rejected case={d} target={s} min={any} resync={d}\n", .{ index, @tagName(target), minify, profile.count(.graph_resync_semantic) });
                try std.testing.expectEqual(provider_resyncs, profile.count(.graph_resync_semantic));
                try helpers.writeFile(tmp.dir, "output.cjs", result.output);
                const output = try helpers.absPath(&tmp, "output.cjs");
                defer std.testing.allocator.free(output);
                const actual = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "node", output } });
                if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, case.expected, actual.stdout)) std.debug.print("legacy field runtime case={d}: {s}\n{s}\n", .{ index, actual.stderr, result.output });
                try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
                try std.testing.expectEqualStrings(case.expected, actual.stdout);
            }
        }
    }
}

const Fixture = struct {
    transformer: @import("transformer.zig").Transformer,
    semantic: module_mod.ModuleSemanticData,
    root: NodeIndex,

    fn init(a: std.mem.Allocator, source: []const u8) !Fixture {
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".ts");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        const ast = try a.create(ast_mod.Ast);
        ast.* = parser.ast;
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, ast);
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var semantic: module_mod.ModuleSemanticData = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .scope_owner_map = analyzer.scope_owner_map, .node_scope_provenance = analyzer.node_scope_provenance, .symbol_ids = analyzer.symbol_ids.items, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .references = analyzer.references.items, .class_self_symbol_map = analyzer.class_self_symbol_map, .helper_scope_map = analyzer.helper_scope_map };
        _ = semantic.captureOwnerToken();
        const options: Options = .{ .experimental_decorators = true };
        const source_plan = (try sourcePlan(a, ast, &semantic, options)) orelse return error.MissingSourcePlan;
        var t = try @import("transformer.zig").Transformer.init(a, ast, options);
        try t.initSymbolIds(semantic.symbol_ids);
        t.symbols = semantic.symbols.items;
        t.references = semantic.references;
        t.scopes = semantic.scopes;
        t.scope_maps = semantic.scope_maps;
        t.scope_owner_map = semantic.scope_owner_map;
        t.node_scope_provenance = semantic.node_scope_provenance;
        t.class_self_symbol_map = semantic.class_self_symbol_map;
        t.helper_scope_map = semantic.helper_scope_map;
        t.unresolved_references = &analyzer.unresolved_references;
        t.semantic_edit_enabled = true;
        t.legacy_assignment_field_source = source_plan;
        const root = try t.transform();
        semantic.applyEdit((try t.finishSemanticEdit()).?);
        return .{ .transformer = t, .semantic = semantic, .root = root };
    }
};

test "legacy scalar assignment fields reject hostile completed owner tuples atomically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, decorate ++ "function sibling(){} @decorate class Example{value:number=2;static count:number=3;other(){return 4;}}");
    try std.testing.expect(try complete(&f.transformer, &f.semantic, f.root));
    const source = f.transformer.legacy_assignment_field_source.?;
    const application = f.transformer.legacy_assignment_field_applications.items[0];
    const applications = f.transformer.legacy_assignment_field_applications.items;
    const applications_before = try a.dupe(Applied, applications);
    const field_before = source.fields[0];
    const references_before = try a.dupe(@import("../semantic/symbol.zig").Reference, f.semantic.references);
    const symbols_before = try a.dupe(@import("../semantic/symbol.zig").Symbol, f.semantic.symbols.items);
    const scopes_before = try a.dupe(@import("../semantic/scope.zig").Scope, f.semantic.scopes);
    var foreign = source.ast.*;
    var foreign_semantic = f.semantic;
    foreign_semantic.owner_token = .unassigned;
    _ = foreign_semantic.captureOwnerToken();
    const static_application = applications_before[1];
    var static_row: ?usize = null;
    for (f.semantic.references, 0..) |row, index| {
        if (row.node_index == static_application.object) static_row = index;
    }
    try std.testing.expect(static_row != null);
    const ids_before = try a.dupe(?u32, f.semantic.symbol_ids);
    for (0..22) |mutation| {
        switch (mutation) {
            0 => f.transformer.legacy_assignment_field_source.?.ast = &foreign,
            1 => f.transformer.legacy_assignment_field_source.?.owner = foreign_semantic.owner_token,
            2 => f.transformer.legacy_assignment_field_applications.items[0].scope = @fromBackingInt(0),
            3 => f.transformer.legacy_assignment_field_applications.items[0].object = application.key,
            4 => f.transformer.legacy_assignment_field_applications.items[0].key = application.value,
            5 => f.transformer.legacy_assignment_field_applications.items[0].value = application.key,
            6 => f.transformer.legacy_assignment_field_applications.items[0].statement = application.value,
            7 => f.transformer.legacy_assignment_field_applications.items = applications[0..1],
            8 => f.transformer.legacy_assignment_field_applications.items[1] = application,
            9 => @constCast(source.fields)[0].node = application.value,
            10 => @constCast(source.fields)[0].class_scope = @fromBackingInt(0),
            11 => @constCast(f.semantic.scopes)[field_before.class_scope.toIndex()].kind = .block,
            12 => f.transformer.legacy_assignment_field_applications.items[1].initializer_function = application.object,
            13 => f.transformer.legacy_assignment_field_applications.items[1].initializer_params = application.key,
            14 => f.transformer.legacy_assignment_field_applications.items[1].initializer_body = application.statement,
            15 => f.transformer.legacy_assignment_field_applications.items[1].initializer_scope = application.scope,
            16 => @constCast(f.semantic.scopes)[static_application.initializer_scope.toIndex()].parent = field_before.class_scope,
            17 => @constCast(f.semantic.references)[static_row.?].flags.write = true,
            18 => @constCast(f.semantic.references)[static_row.?].scope_id = application.scope,
            19 => @constCast(f.semantic.references)[static_row.?].symbol_id = @fromBackingInt(0),
            20 => @constCast(f.semantic.symbol_ids)[@backingInt(static_application.object)] = 0,
            21 => @constCast(source.fields)[1].is_static = false,
            else => unreachable,
        }
        const call_references = try a.dupe(@import("../semantic/symbol.zig").Reference, f.semantic.references);
        const call_symbols = try a.dupe(@import("../semantic/symbol.zig").Symbol, f.semantic.symbols.items);
        const call_scopes = try a.dupe(@import("../semantic/scope.zig").Scope, f.semantic.scopes);
        const call_ids = try a.dupe(?u32, f.semantic.symbol_ids);
        try std.testing.expect(!(try complete(&f.transformer, &f.semantic, f.root)));
        for (call_references, f.semantic.references) |expected, actual| try std.testing.expectEqual(expected, actual);
        for (call_symbols, f.semantic.symbols.items) |expected, actual| try std.testing.expectEqual(expected, actual);
        for (call_scopes, f.semantic.scopes) |expected, actual| try std.testing.expectEqual(expected, actual);
        for (call_ids, f.semantic.symbol_ids) |expected, actual| try std.testing.expectEqual(expected, actual);
        f.transformer.legacy_assignment_field_source = source;
        f.transformer.legacy_assignment_field_applications.items = applications;
        @memcpy(f.transformer.legacy_assignment_field_applications.items, applications_before);
        @constCast(source.fields)[0] = field_before;
        @constCast(source.fields)[1].is_static = true;
        @memcpy(@constCast(f.semantic.scopes), scopes_before);
        @memcpy(@constCast(f.semantic.references), references_before);
        @memcpy(f.semantic.symbols.items, symbols_before);
        @memcpy(@constCast(f.semantic.symbol_ids), ids_before);
        try std.testing.expect(try complete(&f.transformer, &f.semantic, f.root));
    }
}

test "legacy scalar assignment fields keep unsupported source creators on fallback" {
    const negatives = [_][]const u8{
        decorate ++ "@decorate class Example{['value']:number=2;}",
        decorate ++ "@decorate class Example{#value:number=2;}",
        decorate ++ "@decorate class Example{value=()=>2;}",
        decorate ++ "@decorate class Example{value:number;}",
        decorate ++ "class Base{} @decorate class Example extends Base{value:number=2;}",
        decorate ++ "@decorate class Example{static{console.log(1);}value:number=2;}",
        decorate ++ "@decorate class Example{value={};}",
        decorate ++ "var value=@decorate class Example{value:number=2;};",
        decorate ++ "eval(code); @decorate class Example{value:number=2;}",
        decorate ++ "@decorate class Example{value=make();}",
    };
    for (negatives) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".ts");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        try analyzer.analyze();
        var semantic: module_mod.ModuleSemanticData = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .scope_owner_map = analyzer.scope_owner_map, .symbol_ids = analyzer.symbol_ids.items, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .references = analyzer.references.items };
        try std.testing.expect((try sourcePlan(a, &parser.ast, &semantic, .{ .experimental_decorators = true })) == null);
    }
}

test "legacy scalar assignment fields require the source class binding declaration authority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "var unrelated=0;" ++ decorate ++ "@decorate class Example{value:number=2;}");
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_stmt_info = true;
    // This is the production bundler's legitimate mode: statement info alone
    // creates actual declaration anchors; exact-only mode is not required.
    try analyzer.analyze();
    var sem: module_mod.ModuleSemanticData = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .scope_owner_map = analyzer.scope_owner_map, .symbol_ids = analyzer.symbol_ids.items, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .references = analyzer.references.items };
    const options: Options = .{ .experimental_decorators = true };
    const valid = (try sourcePlan(a, &parser.ast, &sem, options)).?;
    const field = valid.fields[0];
    const binding = parser.ast.readExtraNode(parser.ast.getNode(field.class).data.extra, ast_mod.ClassExtra.name);
    var declaration: ?usize = null;
    for (sem.references, 0..) |row, index| {
        if (row.declaration_node_index == binding and row.flags.declare) declaration = index;
    }
    try std.testing.expect(declaration != null);
    const row = sem.references[declaration.?];
    const symbol = sem.symbols.items[field.symbol];
    const refs = sem.references;
    for (0..7) |mutation| {
        switch (mutation) {
            0 => sem.symbols.items[field.symbol].kind = .variable_var,
            1 => @constCast(sem.symbol_ids)[@backingInt(binding)] = 0, // valid same-scope unrelated var SID
            2 => @constCast(sem.references)[declaration.?].flags.read = true,
            3 => {
                const next = try a.alloc(@import("../semantic/symbol.zig").Reference, refs.len + 1);
                @memcpy(next[0..refs.len], refs);
                next[refs.len] = row;
                sem.references = next;
            },
            4 => @constCast(sem.references)[declaration.?].declaration_node_index = .none,
            5 => sem.symbols.items[field.symbol].synthetic_kind = .implicit_arguments,
            6 => sem.symbols.items[field.symbol].synthetic_name = "generated_class",
            else => unreachable,
        }
        try std.testing.expect((try sourcePlan(a, &parser.ast, &sem, options)) == null);
        sem.references = refs;
        @constCast(sem.references)[declaration.?] = row;
        sem.symbols.items[field.symbol] = symbol;
        @constCast(sem.symbol_ids)[@backingInt(binding)] = field.symbol;
        try std.testing.expect((try sourcePlan(a, &parser.ast, &sem, options)) != null);
    }
}
