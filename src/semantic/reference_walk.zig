//! Runtime identifier-reference positions reachable from an AST subtree.
//!
//! This walks *edges*, not just tags: an identifier used as a static property
//! name is not a reference, even though the same NodeIndex may also occur in
//! the value slot. Filtering happens before the visited-node check. Each
//! eligible NodeIndex is reported once; Reference storage is keyed by that
//! index, so repeated eligible edges do not represent distinct References.
//! No name lookup, scope traversal, or Reference creation happens here.
//! Reachability needs only AST edges; callers must use their existing
//! Reference/scope-owner maps to decide whether a surviving node belongs to
//! the migrated loop body and whether its recorded scope is still valid.
//! The AST metadata deliberately omits some syntax-specific children; the
//! export specifier, decorator, and enum member lists are added explicitly.
//! Flow `match` needs contextual edges: value patterns are references, while
//! wildcard and newly bound names are not.
//! JSX names use `jsx_identifier`, a different tag, and are outside this API.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Ast = ast_mod.Ast;

/// Caller owns the returned slice and must free it with `allocator.free`.
/// Descends into nested functions and classes. `root` may be a program, a
/// statement, or an expression. Traversal order is deterministic structural
/// preorder; decorator lists follow the structural children.
pub fn collectIdentifierReferences(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
) error{OutOfMemory}![]NodeIndex {
    // Only subtree nodes enter this map. Repeating this walk for many loops
    // must not clear arrays proportional to the entire transformed AST.
    // Bits: value visit, match-pattern visit, result emitted.
    var states: std.AutoHashMapUnmanaged(u32, u8) = .empty;
    defer states.deinit(allocator);

    var result: std.ArrayList(NodeIndex) = .empty;
    errdefer result.deinit(allocator);
    var stack: std.ArrayList(Edge) = .empty;
    defer stack.deinit(allocator);
    var children: std.ArrayList(Edge) = .empty;
    defer children.deinit(allocator);
    try stack.append(allocator, .{ .idx = root, .context = .value });

    while (stack.pop()) |edge| {
        const idx = edge.idx;
        if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) continue;
        const raw: u32 = @intFromEnum(idx);
        const bit: u8 = if (edge.context == .value) 1 else 2;
        const gop = try states.getOrPut(allocator, raw);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        if ((gop.value_ptr.* & bit) != 0) continue;
        gop.value_ptr.* |= bit;
        const node = ast.nodes.items[raw];
        if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) {
            const is_wildcard = edge.context == .match_pattern and
                std.mem.eql(u8, ast.identifierNameText(node), "_");
            if (!is_wildcard and (gop.value_ptr.* & 4) == 0) {
                try result.append(allocator, idx);
                gop.value_ptr.* |= 4;
            }
            continue;
        }
        if (isTypeOnly(node.tag) or node.tag == .import_declaration or
            node.tag == .import_specifier or node.tag == .export_all_declaration)
        {
            continue;
        }
        if (node.tag == .ts_module_declaration and node.data.binary.flags == 1) continue;

        children.clearRetainingCapacity();
        var it = ast_walk.children(ast, node);
        while (it.next()) |child| {
            const slot = it.cursor - 1;
            if (acceptChild(ast, node, slot, child)) {
                try children.append(allocator, .{
                    .idx = child,
                    .context = childContext(node.tag, slot),
                });
            }
        }
        try appendExtraEdges(ast, node, &children, allocator);
        var i = children.items.len;
        while (i > 0) {
            i -= 1;
            try stack.append(allocator, children.items[i]);
        }
    }
    return result.toOwnedSlice(allocator);
}

const Context = enum { value, match_pattern };
const Edge = struct { idx: NodeIndex, context: Context };

fn childContext(tag: Node.Tag, slot: u32) Context {
    return switch (tag) {
        .flow_match_arm, .flow_match_guard_pattern => if (slot == 0) .match_pattern else .value,
        .flow_match_as_pattern, .flow_match_or_pattern, .flow_match_object_pattern, .flow_match_array_pattern, .flow_match_object_prop => .match_pattern,
        .flow_match_instance_pattern => if (slot == 0) .value else .match_pattern,
        // Generic expression nodes inside patterns evaluate their children as
        // values. In particular `obj[_]` is a value expression, not wildcard.
        else => .value,
    };
}

pub fn isTypeOnly(tag: Node.Tag) bool {
    return switch (tag) {
        .ts_type_reference,
        .ts_qualified_name,
        .ts_array_type,
        .ts_named_tuple_member,
        .ts_conditional_type,
        .ts_indexed_access_type,
        .ts_function_type,
        .ts_constructor_type,
        .ts_mapped_type,
        .ts_template_literal_type,
        .ts_infer_type,
        .ts_parenthesized_type,
        .ts_import_type,
        .ts_type_query,
        .ts_type_alias_declaration,
        .ts_interface_declaration,
        .ts_property_signature,
        .ts_method_signature,
        .ts_call_signature,
        .ts_construct_signature,
        .ts_index_signature,
        .ts_getter_signature,
        .ts_setter_signature,
        .ts_type_parameter,
        .ts_this_parameter,
        .ts_class_implements,
        .ts_type_predicate,
        .ts_external_module_reference,
        .ts_namespace_export_declaration,
        .ts_union_type,
        .ts_intersection_type,
        .ts_tuple_type,
        .ts_type_literal,
        .ts_interface_body,
        .ts_type_parameter_declaration,
        .ts_type_parameter_instantiation,
        .ts_optional_type,
        .ts_rest_type,
        .ts_type_operator,
        .ts_literal_type,
        .flow_type_reference,
        .flow_qualified_name,
        .flow_array_type,
        .flow_function_type,
        .flow_parenthesized_type,
        .flow_type_query,
        .flow_type_parameter,
        .flow_this_parameter,
        .flow_type_alias_declaration,
        .flow_opaque_type,
        .flow_interface_declaration,
        .flow_union_type,
        .flow_intersection_type,
        .flow_tuple_type,
        .flow_object_type,
        .flow_exact_object_type,
        .flow_type_parameter_declaration,
        .flow_type_parameter_instantiation,
        .flow_nullable_type,
        .flow_property_signature,
        .flow_object_spread_property,
        => true,
        else => false,
    };
}

fn isComputed(ast: *const Ast, idx: NodeIndex) bool {
    return !idx.isNone() and @intFromEnum(idx) < ast.nodes.items.len and
        ast.getNode(idx).tag == .computed_property_key;
}

fn acceptChild(ast: *const Ast, parent: Node, slot: u32, child: NodeIndex) bool {
    if (child.isNone() or @intFromEnum(child) >= ast.nodes.items.len) return false;
    return switch (parent.tag) {
        .object_property => slot != 0 or parent.data.binary.right.isNone() or isComputed(ast, child),
        .binding_property, .assignment_target_property_property, .flow_match_object_prop => slot != 0 or isComputed(ast, child),
        .flow_match_as_pattern => slot != 1,
        // Shorthand target's left is the write; right is its default value.
        .assignment_target_property_identifier => true,
        .method_definition, .property_definition, .accessor_property => slot != 0 or isComputed(ast, child),
        .static_member_expression, .private_field_expression => slot != 1,
        .labeled_statement => slot != 0,
        .break_statement, .continue_statement => false,
        .jsx_attribute, .jsx_namespaced_name => slot != 0,
        .import_attribute => false,
        .export_specifier => slot == 0 and (parent.data.binary.flags & 1) == 0,
        .export_named_declaration => slot == 0,
        .ts_enum_member, .flow_enum_member => slot != 0,
        .ts_module_declaration => slot != 0,
        .ts_import_equals_declaration => slot != 0,
        else => true,
    };
}

fn appendExtraList(
    ast: *const Ast,
    e: u32,
    start_off: u32,
    len_off: u32,
    context: Context,
    out: *std.ArrayList(Edge),
    allocator: std.mem.Allocator,
) error{OutOfMemory}!void {
    const extra = ast.extra_data.items;
    if (e >= extra.len or start_off >= extra.len - e or len_off >= extra.len - e) return;
    const start = extra[e + start_off];
    const len = extra[e + len_off];
    if (start > extra.len or len > extra.len - start) return;
    for (extra[start .. start + len]) |raw| try out.append(allocator, .{ .idx = @enumFromInt(raw), .context = context });
}

fn appendExtraEdges(
    ast: *const Ast,
    node: Node,
    out: *std.ArrayList(Edge),
    allocator: std.mem.Allocator,
) error{OutOfMemory}!void {
    switch (node.tag) {
        .export_named_declaration => {
            const e = node.data.extra;
            const extra = ast.extra_data.items;
            // Re-exports have no local reference position. `children` omits
            // the specifier list, so add it only for `export {local}`.
            if (e < extra.len and extra.len - e >= 4 and
                @as(NodeIndex, @enumFromInt(extra[e + 3])).isNone())
            {
                try appendExtraList(ast, e, 1, 2, .value, out, allocator);
            }
        },
        .class_declaration, .class_expression => try appendExtraList(ast, node.data.extra, ast_mod.ClassExtra.deco_start, ast_mod.ClassExtra.deco_len, .value, out, allocator),
        .method_definition => try appendExtraList(ast, node.data.extra, ast_mod.MethodExtra.deco_start, ast_mod.MethodExtra.deco_len, .value, out, allocator),
        .property_definition, .accessor_property => try appendExtraList(ast, node.data.extra, ast_mod.PropertyExtra.deco_start, ast_mod.PropertyExtra.deco_len, .value, out, allocator),
        .formal_parameter => try appendExtraList(ast, node.data.extra, ast_mod.FormalParameterExtra.deco_start, ast_mod.FormalParameterExtra.deco_len, .value, out, allocator),
        .ts_enum_declaration => {
            const e = node.data.extra;
            const extra = ast.extra_data.items;
            // Parser extra[e+3]: bit0=const, bit1=ambient. Transformer
            // erases both declarations without runtime initializer evaluation.
            if (e < extra.len and extra.len - e >= 4 and extra[e + 3] == 0) {
                try appendExtraList(ast, e, 1, 2, .value, out, allocator);
            }
        },
        .flow_enum_declaration => try appendExtraList(ast, node.data.extra, 1, 2, .value, out, allocator),
        .flow_match_expression => {
            const e = node.data.extra;
            const extra = ast.extra_data.items;
            if (e < extra.len and extra.len - e >= 3) {
                try out.append(allocator, .{ .idx = @enumFromInt(extra[e]), .context = .value });
                try appendExtraList(ast, e, 1, 2, .value, out, allocator);
            }
        },
        else => {},
    }
}

const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;

test "#4819 reference walk: allocation failures propagate without leaks" {
    var scanner = try Scanner.init(std.testing.allocator, "const object = {staticKey: value, [key]: other};");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    const root: NodeIndex = @enumFromInt(@as(u32, @intCast(parser.ast.nodes.items.len - 1)));
    const Check = struct {
        fn run(allocator: std.mem.Allocator, ast: *const Ast, subtree: NodeIndex) !void {
            const refs = try collectIdentifierReferences(allocator, ast, subtree);
            defer allocator.free(refs);
            try std.testing.expectEqual(@as(usize, 3), refs.len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{ &parser.ast, root });
}
const SemanticAnalyzer = @import("analyzer.zig").SemanticAnalyzer;

fn expectNamesWithMode(source: []const u8, expected: []const []const u8, flow: bool) !void {
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_flow = flow;
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    const ast = &parser.ast;
    const root = ast.transformed_root orelse @as(NodeIndex, @enumFromInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
    const refs = try collectIdentifierReferences(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(refs);
    try std.testing.expectEqual(expected.len, refs.len);
    var found = try std.testing.allocator.alloc(bool, expected.len);
    defer std.testing.allocator.free(found);
    @memset(found, false);
    for (refs) |idx| {
        const name = ast.identifierNameText(ast.getNode(idx));
        var matched = false;
        for (expected, 0..) |want, i| {
            if (!found[i] and std.mem.eql(u8, name, want)) {
                found[i] = true;
                matched = true;
                break;
            }
        }
        if (!matched) {
            std.debug.print("unexpected reference {s} in {s}\n", .{ name, source });
            return error.UnexpectedReference;
        }
    }
}

fn expectNames(source: []const u8, expected: []const []const u8) !void {
    return expectNamesWithMode(source, expected, false);
}

fn expectFlowNames(source: []const u8, expected: []const []const u8) !void {
    return expectNamesWithMode(source, expected, true);
}

test "#4819 reference walk: shorthand, static and shared key/value" {
    try expectNames("const o = {x}; const p = {x: y};", &.{ "x", "y" });

    var scanner = try Scanner.init(std.testing.allocator, "const o = {x: y};");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    for (parser.ast.nodes.items) |*node| {
        if (node.tag == .object_property) {
            node.data.binary.right = node.data.binary.left;
            break;
        }
    }
    const ast = &parser.ast;
    const root: NodeIndex = @enumFromInt(@as(u32, @intCast(ast.nodes.items.len - 1)));
    const refs = try collectIdentifierReferences(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(refs);
    try std.testing.expectEqual(@as(usize, 1), refs.len);
    try std.testing.expectEqualStrings("x", ast.identifierNameText(ast.getNode(refs[0])));

    // Two eligible edges to the same leaf still represent one Reference.
    var scanner2 = try Scanner.init(std.testing.allocator, "a + b;");
    defer scanner2.deinit();
    var parser2 = Parser.init(std.testing.allocator, &scanner2);
    defer parser2.deinit();
    _ = try parser2.parse();
    for (parser2.ast.nodes.items) |*node| {
        if (node.tag == .binary_expression) {
            node.data.binary.right = node.data.binary.left;
            break;
        }
    }
    const root2: NodeIndex = @enumFromInt(@as(u32, @intCast(parser2.ast.nodes.items.len - 1)));
    const repeated = try collectIdentifierReferences(std.testing.allocator, &parser2.ast, root2);
    defer std.testing.allocator.free(repeated);
    try std.testing.expectEqual(@as(usize, 1), repeated.len);
}

test "#4819 reference walk: computed keys and assignment writes" {
    try expectNames("const {[key]: local = fallback} = input;", &.{ "key", "fallback", "input" });
    try expectNames("const {staticKey: local = fallback} = input;", &.{ "fallback", "input" });
    try expectNames("({[key]: target = fallback} = input);", &.{ "key", "target", "fallback", "input" });
    try expectNames("({target = fallback} = input);", &.{ "target", "fallback", "input" });
    try expectNames("[first, ...rest] = input;", &.{ "first", "rest", "input" });

    var scanner = try Scanner.init(std.testing.allocator, "[first] = input;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    const ast = &parser.ast;
    const root: NodeIndex = @enumFromInt(@as(u32, @intCast(ast.nodes.items.len - 1)));
    const refs = try collectIdentifierReferences(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(refs);
    var saw_write = false;
    for (refs) |idx| {
        if (ast.getNode(idx).tag == .assignment_target_identifier) saw_write = true;
    }
    try std.testing.expect(saw_write);
}

test "#4819 reference walk: decorators and nested closures" {
    try expectNames("@dec class C { @member [key] = init; }", &.{ "dec", "member", "key", "init" });
    try expectNames("class C { @methodDec [methodKey]() { return bodyRef; } }", &.{ "methodDec", "methodKey", "bodyRef" });
    try expectNames("function outer(a = fallback) { return () => a + captured; }", &.{ "fallback", "a", "captured" });
}

test "#4819 reference walk: exports, labels and members" {
    try expectNames("const local = 1; export {local as exported};", &.{"local"});
    try expectNames("export {remote as alias} from 'mod';", &.{});
    try expectNames("import {remote as local} from 'mod'; local;", &.{"local"});
    try expectNames("export {type TypeName, value as exported};", &.{"value"});
    try expectNames("label: while (condition) { break label; }", &.{"condition"});
    try expectNames("object.property; object[key];", &.{ "object", "object", "key" });
}

test "#4819 reference walk: type-only and runtime enum initializer" {
    try expectNames("const result = value as TypeName;", &.{"value"});
    try expectNames("const result = value satisfies TypeName;", &.{"value"});
    try expectNames("const result = maybe!;", &.{"maybe"});
    try expectNames("const result = <TypeName>value;", &.{"value"});
    try expectFlowNames("const result = (value: TypeName);", &.{"value"});
    try expectNames("enum E { A = init }", &.{"init"});
    try expectNames("const enum E { A = erased }", &.{});
    try expectNames("declare enum Ghost { A = erased } const live = actual;", &.{"actual"});
    try expectNames("namespace Outer { export declare enum Ghost { A = ghost } const live = actual; }", &.{"actual"});
    try expectNames("namespace Outer { export declare const enum Hidden { A = erased } const live = actual; }", &.{"actual"});
    try expectNames("export type { TypeName };", &.{});
    try expectNames("declare namespace Hidden { export const fake = ghost; } const live = actual;", &.{"actual"});
    try expectNames("namespace Live { const nested = actual; }", &.{"actual"});
    try expectNames("namespace Outer { export declare const fake: TypeName; const live = actual; }", &.{"actual"});
    try expectNames("namespace Outer { export declare namespace Hidden { export const fake = ghost; } const live = actual; }", &.{"actual"});
}

test "#4819 reference walk: original Flow match subject, value patterns, guard and body" {
    try expectFlowNames(
        "const out = match (subject) { valuePattern if (guardRef) => bodyRef, _ => fallbackRef };",
        &.{ "subject", "valuePattern", "guardRef", "bodyRef", "fallbackRef" },
    );
    try expectFlowNames(
        "const out = match (subject) { Choice.Member => bodyRef, _ => fallbackRef };",
        &.{ "subject", "Choice", "bodyRef", "fallbackRef" },
    );
    try expectFlowNames(
        "const out = match (subject) { Choice[computed] => bodyRef, _ => fallbackRef };",
        &.{ "subject", "Choice", "computed", "bodyRef", "fallbackRef" },
    );
}

test "#4819 reference walk: original Flow match bindings are positions only where used" {
    try expectFlowNames(
        "const out = match (subject) { const bound if (guardRef) => bound + outer, _ => fallback };",
        &.{ "subject", "guardRef", "bound", "outer", "fallback" },
    );
    try expectFlowNames(
        "const out = match (subject) { valuePattern as alias => alias + outer, _ => fallback };",
        &.{ "subject", "valuePattern", "alias", "outer", "fallback" },
    );
    try expectFlowNames(
        "const out = match (subject) { Ctor {kind: valuePattern, nested: [const inner, ...const rest]} if (guardRef) => inner + rest + bodyRef, _ => fallback };",
        &.{ "subject", "Ctor", "valuePattern", "guardRef", "inner", "rest", "bodyRef", "fallback" },
    );
    try expectFlowNames(
        "const out = match (subject) { _ => _, };",
        &.{ "subject", "_" },
    );

    // A leaf first seen as a wildcard can be reused as a value. Contextual
    // visited bits must not hide that value position.
    var scanner = try Scanner.init(std.testing.allocator, "const out = match (subject) { _ => 0 }; ");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_flow = true;
    _ = try parser.parse();
    for (parser.ast.nodes.items) |*node| {
        if (node.tag == .flow_match_arm) {
            node.data.binary.right = node.data.binary.left;
            break;
        }
    }
    const ast = &parser.ast;
    const root: NodeIndex = @enumFromInt(@as(u32, @intCast(ast.nodes.items.len - 1)));
    const refs = try collectIdentifierReferences(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(refs);
    try std.testing.expectEqual(@as(usize, 2), refs.len);
}

test "#4819 reference walk: value Reference node set matches analyzer on resolved loop-like body" {
    const source =
        \\const key = 'k', fallback = 1, sourceValue = {}, outer = 2;
        \\let target = 0;
        \\function f(param = fallback) {
        \\  const {[key]: local = param} = sourceValue;
        \\  ({[key]: target = fallback} = sourceValue);
        \\  return () => local + target + outer;
        \\}
    ;
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    defer analyzer.deinit();
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    const ast = &parser.ast;
    const root: NodeIndex = @enumFromInt(@as(u32, @intCast(ast.nodes.items.len - 1)));
    const positions = try collectIdentifierReferences(allocator, ast, root);
    defer allocator.free(positions);

    var walked: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer walked.deinit(allocator);
    for (positions) |idx| try walked.put(allocator, @intFromEnum(idx), {});
    try std.testing.expect(walked.count() >= 9);

    var analyzed: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer analyzed.deinit(allocator);
    for (analyzer.references.items) |ref| {
        if (!ref.isValueUse() or ref.node_index.isNone()) continue;
        const raw: u32 = @intFromEnum(ref.node_index);
        if (raw >= ast.nodes.items.len) continue;
        const tag = ast.nodes.items[raw].tag;
        if (tag != .identifier_reference and tag != .assignment_target_identifier) continue;
        try analyzed.put(allocator, raw, {});
    }

    try std.testing.expectEqual(analyzed.count(), walked.count());
    var it = walked.keyIterator();
    while (it.next()) |raw| {
        if (!analyzed.contains(raw.*)) {
            std.debug.print("walker-only node {d}: {s}\n", .{ raw.*, ast.identifierNameText(ast.nodes.items[raw.*]) });
            return error.WalkerAnalyzerMismatch;
        }
    }
}
