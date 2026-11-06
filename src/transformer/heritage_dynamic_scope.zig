//! Reject only class lowering that would move potential direct eval from the
//! strict class heritage environment into a sloppy evaluation environment.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");

fn directiveStrict(self: anytype, root: ast.NodeIndex) bool {
    if (root.isNone()) return false;
    const body = self.ast.getNode(root);
    if (body.tag != .program and body.tag != .block_statement) return false;
    const list = body.data.list;
    for (self.ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
        const statement = self.ast.getNode(@fromBackingInt(@intCast(raw)));
        if (statement.tag != .directive) break;
        const text = self.ast.getText(statement.span);
        if (std.mem.eql(u8, text, "\"use strict\"") or std.mem.eql(u8, text, "'use strict'")) return true;
    }
    return false;
}

fn potentialEval(self: anytype, root: ast.NodeIndex) !?@import("../lexer/token.zig").Span {
    var stack: std.ArrayList(ast.NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, root);
    while (stack.pop()) |idx| {
        if (idx.isNone()) continue;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .function_declaration, .function_expression, .arrow_function_expression, .method_definition, .class_declaration, .class_expression => continue,
            else => {},
        }
        if (@import("static_class_capture.zig").isDirectEvalCall(self, node)) return node.span;
        var children = walk.children(self.ast, node);
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
    return null;
}

/// Runs before any source AST, semantic row, or scope history mutation. It
/// selects syntax roles only; an eval binding can still contain the builtin.
pub fn preflight(self: anytype, root: ast.NodeIndex) !bool {
    if (!self.options.unsupported.class) return false;
    const Work = struct { node: ast.NodeIndex, strict: bool, source_strict: bool };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(self.allocator);
    var module_strict = directiveStrict(self, root);
    if (self.outputOwnedScope(root)) |owner| {
        if (owner.toIndex() < self.scopes.len) module_strict = module_strict or self.scopes[owner.toIndex()].is_strict;
    }
    // Graphless source still has its original module syntax.
    const program = self.ast.getNode(root);
    if (program.tag == .program) for (self.ast.extra_data.items[program.data.list.start .. program.data.list.start + program.data.list.len]) |raw| {
        switch (self.ast.getNode(@fromBackingInt(@intCast(raw))).tag) {
            .import_declaration, .export_named_declaration, .export_default_declaration, .export_all_declaration => module_strict = true,
            else => {},
        }
    };
    try stack.append(self.allocator, .{ .node = root, .strict = module_strict, .source_strict = module_strict });
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const node = self.ast.getNode(work.node);
        if (node.tag == .class_declaration or node.tag == .class_expression) {
            const heritage = self.ast.readExtraNode(node.data.extra, ast.ClassExtra.super);
            if (!heritage.isNone()) {
                if (!work.strict) if (try potentialEval(self, heritage)) |span| {
                    self.unsupported_class_heritage_eval_span = span;
                    return true;
                };
                // A nested class in this expression will also be evaluated
                // outside the outer lowered class, so retain the output context.
                try stack.append(self.allocator, .{ .node = heritage, .strict = work.strict, .source_strict = true });
            }
            const body = self.ast.readExtraNode(node.data.extra, ast.ClassExtra.body);
            try stack.append(self.allocator, .{ .node = body, .strict = true, .source_strict = true });
            continue;
        }
        var strict = work.strict;
        var source_strict = work.source_strict;
        switch (node.tag) {
            .function_declaration, .function_expression, .method_definition => {
                source_strict = source_strict or directiveStrict(self, self.ast.readExtraNode(node.data.extra, ast.FunctionExtra.body));
                strict = source_strict;
            },
            .arrow_function_expression => {
                source_strict = source_strict or directiveStrict(self, self.ast.readExtraNode(node.data.extra, ast.ArrowExtra.body));
                strict = source_strict;
            },
            else => {},
        }
        var children = walk.children(self.ast, node);
        while (children.next()) |child| try stack.append(self.allocator, .{ .node = child, .strict = strict, .source_strict = source_strict });
    }
    return false;
}

test "class heritage eval preflight preserves syntax boundaries before editing" {
    const Parser = @import("../parser/parser.zig").Parser;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Transformer = @import("transformer.zig").Transformer;
    const compat = @import("compat.zig");
    const cases = [_]struct { source: []const u8, rejects: bool }{
        .{ .source = "class C extends eval('Base'){}", .rejects = true },
        .{ .source = "class C extends (eval)('Base'){}", .rejects = true },
        .{ .source = "class C extends(class extends eval('Base'){}){}", .rejects = true },
        .{ .source = "class C extends (0,eval)('Base'){}", .rejects = false },
        .{ .source = "class C extends eval?.('Base'){}", .rejects = false },
        .{ .source = "class C extends Base{method(){return eval('Base')}}", .rejects = false },
        .{ .source = "class C extends(function(){return eval('Base')})(){}", .rejects = false },
        .{ .source = "class C extends(()=>eval('Base'))(){}", .rejects = false },
        .{ .source = "'use strict';class C extends eval('Base'){}", .rejects = false },
        .{ .source = "function run(){'use strict';class C extends eval('Base'){}}", .rejects = false },
        .{ .source = "export class C extends eval('Base'){}", .rejects = false },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, case.source);
        var parser = Parser.init(a, &scanner);
        if (std.mem.startsWith(u8, case.source, "export ")) {
            scanner.is_module = true;
            parser.is_module = true;
        }
        const root = try parser.parse();
        if (parser.errors.items.len != 0) std.debug.print("HERITAGE_PREFLIGHT_PARSE source={s} errors={d}\n", .{ case.source, parser.errors.items.len });
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var transformer = try Transformer.initFromOwnedAst(a, &parser.ast, .{ .unsupported = compat.fromESTarget(.es5) });
        const node_count = transformer.ast.nodes.items.len;
        const extra_count = transformer.ast.extra_data.items.len;
        const string_count = transformer.ast.string_table.items.len;
        try std.testing.expectEqual(case.rejects, try preflight(&transformer, root));
        try std.testing.expectEqual(node_count, transformer.ast.nodes.items.len);
        try std.testing.expectEqual(extra_count, transformer.ast.extra_data.items.len);
        try std.testing.expectEqual(string_count, transformer.ast.string_table.items.len);
        try std.testing.expect(transformer.semantic_editor == null);
        transformer.unsupported_class_heritage_eval_span = null;
        transformer.options.unsupported = compat.fromESTarget(.esnext);
        try std.testing.expect(!try preflight(&transformer, root));
        try std.testing.expect(transformer.unsupported_class_heritage_eval_span == null);
    }
}

test "class heritage eval healthy runtime controls preserve their source behavior" {
    const helpers = @import("../bundler/test_helpers.zig");
    const Bundler = @import("../bundler/bundler.zig").Bundler;
    const compat = @import("compat.zig");
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        "globalThis.Base=class{value(){return 42}};class C extends(0,eval)('globalThis.Base'){};console.log(new C().value())",
        "globalThis.Base=class{value(){return 42}};class C extends eval?.('globalThis.Base'){};console.log(new C().value())",
        "globalThis.Base=class{value(){return 42}};class C extends(function(){return eval('globalThis.Base')})(){};console.log(new C().value())",
        "globalThis.Base=class{value(){return 42}};class C extends(()=>eval('globalThis.Base'))(){};console.log(new C().value())",
        "globalThis.Base=class{value(){return 42}};class C extends globalThis.Base{method(){return eval('42')}};console.log(new C().method())",
        "'use strict';delete globalThis.__heritageLeak;globalThis.Base=class{};try{class C extends eval('(__heritageLeak=1,globalThis.Base)'){};}catch(error){console.log(JSON.stringify([error.name,typeof globalThis.__heritageLeak]))}",
        "function run(){'use strict';delete globalThis.__heritageLeak;globalThis.Base=class{};try{class C extends eval('(__heritageLeak=1,globalThis.Base)'){};}catch(error){console.log(JSON.stringify([error.name,typeof globalThis.__heritageLeak]))}}run()",
    };
    for (cases) |source| {
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        defer a.free(native.stdout);
        defer a.free(native.stderr);
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]compat.ESTarget{ .es5, .esnext }) |target| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try helpers.writeFile(tmp.dir, "entry.cjs", source);
            const entry = try helpers.absPath(&tmp, "entry.cjs");
            defer a.free(entry);
            var bundler = Bundler.init(a, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .unsupported = compat.fromESTarget(target) });
            defer bundler.deinit();
            const result = try bundler.bundle(std.testing.io);
            defer result.deinit(a);
            try std.testing.expect(!result.hasErrors());
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.output } });
            defer a.free(actual.stdout);
            defer a.free(actual.stderr);
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}
