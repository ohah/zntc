const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const facts = @import("constant_facts.zig");

test "constant materialization preserves export lexical edges in ten source forms" {
    const cases = [_][]const u8{
        "const value=42;export {value};use(value);",
        "const count=42;export {count as answer};use(count);",
        "const message=42;export {message as 'public name'};use(message);",
        "import {value as imported} from 'dep';export {imported};use(imported);",
        "import fallback from 'dep';export {fallback};use(fallback);",
        "export {late};const late=42;use(late);",
        "const exact=42;export {exact as exact};use(exact);",
        "const selected=42;export {selected as default};use(selected);",
        "const v\\u0061lue=42;export {value};use(value);",
        "const value=42;export {value,value as other};use(value);",
    };
    var bad_cases: usize = 0;
    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try Scanner.init(allocator, source);
        var parser = Parser.init(allocator, &scanner);
        parser.is_module = true;
        const root = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = Analyzer.init(allocator, &parser.ast);
        analyzer.is_module = true;
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        var value_id: ?u32 = null;
        const Slot = struct { local: NodeIndex, public: NodeIndex };
        var exports: std.ArrayList(Slot) = .empty;
        for (parser.ast.nodes.items) |node| {
            if (node.tag != .export_specifier) continue;
            try exports.append(allocator, .{ .local = node.data.binary.left, .public = node.data.binary.right });
            const id = analyzer.symbol_ids.items[@backingInt(node.data.binary.left)].?;
            if (value_id) |previous| try std.testing.expectEqual(previous, id);
            value_id = id;
        }
        const sid = value_id orelse return error.MissingExportReference;
        var eligible = try std.DynamicBitSet.initEmpty(allocator, parser.ast.nodes.items.len);
        var runtime_read: ?NodeIndex = null;
        for (analyzer.references.items) |reference| {
            if (!reference.isValueUse() or reference.node_index.isNone()) continue;
            eligible.set(@backingInt(reference.node_index));
            if (@backingInt(reference.symbol_id) != sid) continue;
            var lexical = false;
            for (exports.items) |slot| if (slot.local == reference.node_index) {
                lexical = true;
            };
            if (!lexical) runtime_read = reference.node_index;
        }
        var values: std.AutoHashMapUnmanaged(u32, @import("../semantic/symbol.zig").ConstValue) = .empty;
        try values.put(allocator, sid, .{ .kind = .number, .number_text = "42" });
        var tracked: std.ArrayList(NodeIndex) = .empty;
        const result = facts.materializeWithScratchDetailed(allocator, &parser.ast, analyzer.symbol_ids.items, &values, null, 0, .{}, false, &eligible, &tracked);
        try std.testing.expect(result.changed and result.tracked_nodes_complete);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.numeric_literal, parser.ast.getNode(runtime_read.?).tag);
        var mismatch = false;
        for (exports.items) |slot| {
            if (parser.ast.getNode(slot.local).tag != .identifier_reference) mismatch = true;
            for (tracked.items) |node| if (node == slot.local or node == slot.public) {
                mismatch = true;
            };
            try std.testing.expectEqual(@as(?u32, sid), analyzer.symbol_ids.items[@backingInt(slot.local)]);
        }
        if (mismatch) {
            bad_cases += 1;
        } else {
            var codegen = @import("../codegen/codegen.zig").Codegen.init(allocator, &parser.ast);
            const code = try codegen.generate(root);
            var rescanner = try Scanner.init(allocator, code);
            var reparsed = Parser.init(allocator, &rescanner);
            reparsed.is_module = true;
            _ = try reparsed.parse();
            try std.testing.expectEqual(@as(usize, 0), reparsed.errors.items.len);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad_cases);
}

test "constant materialization keeps shorthand grammar while folding ordinary reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const value=42;use({value},value);");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = Analyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var shorthand: ?NodeIndex = null;
    for (parser.ast.nodes.items) |node| {
        if (node.tag == .object_property and node.data.binary.right.isNone()) shorthand = node.data.binary.left;
    }
    const key = shorthand orelse return error.MissingShorthand;
    const sid = analyzer.symbol_ids.items[@backingInt(key)].?;
    var values: std.AutoHashMapUnmanaged(u32, @import("../semantic/symbol.zig").ConstValue) = .empty;
    try values.put(allocator, sid, .{ .kind = .number, .number_text = "42" });
    var eligible = try std.DynamicBitSet.initEmpty(allocator, parser.ast.nodes.items.len);
    var runtime: ?NodeIndex = null;
    for (analyzer.references.items) |reference| {
        if (!reference.isValueUse() or reference.node_index.isNone()) continue;
        eligible.set(@backingInt(reference.node_index));
        if (@backingInt(reference.symbol_id) == sid and reference.node_index != key) runtime = reference.node_index;
    }
    const result = facts.materializeWithScratchDetailed(allocator, &parser.ast, analyzer.symbol_ids.items, &values, null, 0, .{}, false, &eligible, null);
    try std.testing.expect(result.changed);
    try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, parser.ast.getNode(key).tag);
    try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.numeric_literal, parser.ast.getNode(runtime.?).tag);
}
