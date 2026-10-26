const std = @import("std");

test "static block environment initial var identity is independent per actual static block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "class C{static{console.log(value);{var value=3}this.a=()=>value}static{var value=9;this.b=()=>value}}";
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    _ = try parser.parse();
    var initial = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    initial.enable_exact_declaration_anchors = true;
    try initial.analyze();
    try std.testing.expectEqual(@as(usize, 0), initial.errors.items.len);
    var ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or !std.mem.eql(u8, parser.ast.getText(node.span), "value")) continue;
        const sid = initial.symbol_ids.items[raw] orelse return error.MissingStaticVarId;
        const scope = initial.symbols.items[sid].scope_id;
        try std.testing.expectEqual(.class_static_block, initial.scopes.items[scope.toIndex()].kind);
        try std.testing.expect(!ids.contains(sid));
        try ids.put(a, sid, {});
        var owner_count: usize = 0;
        var owners = initial.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (entry.value_ptr.* != @backingInt(scope)) continue;
            if (parser.ast.nodes.items[entry.key_ptr.*].tag == .block_statement) continue;
            try std.testing.expectEqual(.static_block, parser.ast.nodes.items[entry.key_ptr.*].tag);
            const body = parser.ast.nodes.items[entry.key_ptr.*].data.unary.operand;
            try std.testing.expectEqual(entry.value_ptr.*, initial.scope_owner_map.get(@backingInt(body)).?);
            owner_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), owner_count);
    }
    try std.testing.expectEqual(@as(usize, 2), ids.count());
    var reads: usize = 0;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .identifier_reference or !std.mem.eql(u8, parser.ast.getText(node.span), "value")) continue;
        const sid = initial.symbol_ids.items[raw] orelse return error.MissingHoistedStaticVarRead;
        try std.testing.expect(ids.contains(sid));
        reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), reads);
}

test "static block environment lowered storage and reference scopes exist before finalization" {
    for ([_]@import("compat.zig").ESTarget{ .es2015, .es2017, .es5 }) |target| {
        const utils = @import("output_scope_test_utils.zig");
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = "class C{static{var value=3;this.a=()=>value;console.log(value,C===this)}static{var value=9;this.b=()=>value;console.log(value,C===this)}}console.log(C.a(),C.b());class D{static{this.ref=this}}";
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        const root = try parser.parse();
        var initial = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        initial.enable_stmt_info = true;
        initial.enable_exact_declaration_anchors = true;
        try initial.analyze();
        var ids: std.ArrayList(u32) = .empty;
        for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag == .binding_identifier and std.mem.eql(u8, parser.ast.getText(node.span), "value"))
                try ids.append(a, initial.symbol_ids.items[raw].?);
        }
        var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{ .unsupported = @import("options.zig").TransformOptions.compat.fromESTarget(target) });
        try t.initSymbolIdsOwned(&parser.ast, initial.symbol_ids.items);
        t.symbols = initial.symbols.items;
        t.references = initial.references.items;
        t.scopes = initial.scopes.items;
        t.scope_maps = initial.scope_maps.items;
        t.scope_owner_map = initial.scope_owner_map;
        t.node_scope_provenance = initial.node_scope_provenance;
        t.class_self_symbol_map = initial.class_self_symbol_map;
        t.unresolved_references = &initial.unresolved_references;
        t.semantic_edit_enabled = true;
        try t.buildBlockRenameMap();
        const output = try t.visitNode(root);
        var parents = try utils.buildParentMap(a, t.ast, output);
        var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        if (t.outputOwnedScope(output)) |scope| try owners.put(a, @backingInt(output), @backingInt(scope));
        var keys = parents.keyIterator();
        while (keys.next()) |raw| if (t.outputOwnedScope(@fromBackingInt(raw.*))) |scope| {
            try owners.put(a, raw.*, @backingInt(scope));
        };
        const editor = &t.semantic_editor.?;
        var consumed_self: usize = 0;
        for (initial.references.items) |source_ref| {
            if (source_ref.flags.declare or initial.scopes.items[source_ref.scope_id.toIndex()].kind != .class_static_block) continue;
            if (initial.symbols.items[@backingInt(source_ref.symbol_id)].scope_id == source_ref.scope_id) continue;
            var is_class_self = false;
            var self_ids = initial.class_self_symbol_map.valueIterator();
            while (self_ids.next()) |id| if (@backingInt(source_ref.symbol_id) == id.*) {
                is_class_self = true;
                break;
            };
            if (!is_class_self) continue;
            try std.testing.expect((try editor.referenceForNode(source_ref.node_index)) == null);
            try std.testing.expectEqual(@as(?u32, null), editor.symbol_ids.items[@backingInt(source_ref.node_index)]);
            consumed_self += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), consumed_self);
        var replacements: usize = 0;
        var identity_origins = t.static_class_reference_origins.iterator();
        while (identity_origins.next()) |entry| {
            const node: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(entry.key_ptr.*);
            const proof = entry.value_ptr.*;
            try std.testing.expect(@import("static_class_capture.zig").validOwnReferenceOrigin(&t, node));
            try std.testing.expectEqual(initial.symbol_ids.items[@backingInt(proof.source)].?, proof.source_symbol_id);
            try std.testing.expect((try editor.referenceForNode(proof.source)) == null);
            try std.testing.expect(proof.source_symbol_id != @backingInt(proof.reference.symbol_id));
            var snapshot_values: usize = 0;
            var live_nodes = parents.keyIterator();
            while (live_nodes.next()) |live_raw| {
                const candidate = t.ast.nodes.items[live_raw.*];
                if (candidate.tag != .variable_declarator) continue;
                const binding = t.ast.readExtraNode(candidate.data.extra, 0);
                if (t.getSymbolIdAt(binding) != @backingInt(proof.reference.symbol_id)) continue;
                const value = t.ast.readExtraNode(candidate.data.extra, 2);
                try std.testing.expectEqual(.identifier_reference, t.ast.getNode(value).tag);
                try std.testing.expectEqual(proof.class_value_symbol_id, t.getSymbolIdAt(value).?);
                try std.testing.expectEqual(proof.class_value_symbol_id, @backingInt((try editor.referenceForNode(value)).?.symbol_id));
                snapshot_values += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), snapshot_values);
            var row: usize = 0;
            while (editor.references.items[row].node_index != node) : (row += 1) {}
            const saved = editor.references.items[row];
            // Both alternatives are real IDs/scopes from this graph. Numeric
            // range checks alone cannot authorize an identity-origin escape.
            editor.references.items[row].symbol_id = @fromBackingInt(ids.items[0]);
            try std.testing.expect(!@import("static_class_capture.zig").validOwnReferenceOrigin(&t, node));
            editor.references.items[row] = saved;
            editor.references.items[row].scope_id = t.programScope();
            try std.testing.expect(!@import("static_class_capture.zig").validOwnReferenceOrigin(&t, node));
            editor.references.items[row] = saved;
            editor.references.items[row].flags = .{ .write = true };
            try std.testing.expect(!@import("static_class_capture.zig").validOwnReferenceOrigin(&t, node));
            editor.references.items[row] = saved;
            editor.references.items[row].stmt_idx = if (saved.stmt_idx == 0) 1 else 0;
            try std.testing.expect(!@import("static_class_capture.zig").validOwnReferenceOrigin(&t, node));
            editor.references.items[row] = saved;
            editor.references.items[row].scope_stmt_idx = if (saved.scope_stmt_idx == 0) 1 else 0;
            try std.testing.expect(!@import("static_class_capture.zig").validOwnReferenceOrigin(&t, node));
            editor.references.items[row] = saved;
            entry.value_ptr.source_symbol_id = ids.items[0];
            try std.testing.expect(!@import("static_class_capture.zig").validOwnReferenceOrigin(&t, node));
            entry.value_ptr.* = proof;
            const source_staging_id = t.symbol_ids.items[@backingInt(proof.source)];
            t.symbol_ids.items[@backingInt(proof.source)] = ids.items[0];
            try std.testing.expect(!@import("static_class_capture.zig").validOwnReferenceOrigin(&t, node));
            t.symbol_ids.items[@backingInt(proof.source)] = source_staging_id;
            try std.testing.expectEqual(@as(u32, 0), t.static_class_captures.count());
            var other_capture = t.completed_static_class_captures.iterator();
            var checked_other = false;
            while (other_capture.next()) |other| {
                if (other.key_ptr.* == @backingInt(proof.class_binding)) continue;
                entry.value_ptr.class_value_symbol_id = other.value_ptr.frame.class_symbol_id.?;
                try std.testing.expect(!@import("static_class_capture.zig").validOwnReferenceOrigin(&t, node));
                entry.value_ptr.* = proof;
                entry.value_ptr.class_binding = other.value_ptr.frame.class_binding;
                try std.testing.expect(!@import("static_class_capture.zig").validOwnReferenceOrigin(&t, node));
                entry.value_ptr.* = proof;
                const creator = t.completed_static_class_captures.getPtr(@backingInt(proof.class_binding)).?;
                const saved_creator = creator.*;
                creator.symbol_id = other.value_ptr.symbol_id;
                try std.testing.expect(!@import("static_class_capture.zig").validOwnReferenceOrigin(&t, node));
                creator.* = saved_creator;
                creator.frame.class_self_symbol_id = other.value_ptr.frame.class_self_symbol_id;
                try std.testing.expect(!@import("static_class_capture.zig").validOwnReferenceOrigin(&t, node));
                creator.* = saved_creator;
                creator.frame.class_binding = other.value_ptr.frame.class_binding;
                try std.testing.expect(!@import("static_class_capture.zig").validOwnReferenceOrigin(&t, node));
                creator.* = saved_creator;
                checked_other = true;
                break;
            }
            try std.testing.expect(checked_other);
            const source_raw = @backingInt(proof.source);
            const previous = t.reference_origin_map.get(source_raw);
            try t.reference_origin_map.put(a, source_raw, source_raw);
            try std.testing.expect(!@import("static_class_capture.zig").validOwnReferenceOrigin(&t, proof.source));
            if (previous) |origin| try t.reference_origin_map.put(a, source_raw, origin) else _ = t.reference_origin_map.remove(source_raw);
            try std.testing.expect(@import("static_class_capture.zig").validOwnReferenceOrigin(&t, node));
            replacements += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), replacements);
        for (parser.ast.nodes.items) |source_node| {
            if (source_node.tag != .static_block) continue;
            const source_body = source_node.data.unary.operand;
            try std.testing.expect(initial.scope_owner_map.contains(@backingInt(source_body)));
            try std.testing.expect(!editor.scope_owner_map.contains(@backingInt(source_body)));
            try std.testing.expect(!t.scope_owner_remaps.contains(@backingInt(source_body)));
        }
        try std.testing.expectEqual(@as(usize, 2), ids.items.len);
        try std.testing.expect(editor.symbols.items[ids.items[0]].scope_id != editor.symbols.items[ids.items[1]].scope_id);
        for (ids.items) |id| {
            const storage = editor.symbols.items[id].scope_id;
            try std.testing.expectEqual(.class_static_block, initial.scopes.items[initial.symbols.items[id].scope_id.toIndex()].kind);
            try std.testing.expectEqual(.function, editor.scopes.items[storage.toIndex()].kind);
            var actual_owners: usize = 0;
            var it = owners.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != @backingInt(storage)) continue;
                if (t.ast.nodes.items[entry.key_ptr.*].tag == .block_statement) {
                    const actual_parent = parents.get(entry.key_ptr.*).?;
                    const owner = t.ast.nodes.items[actual_parent];
                    try std.testing.expectEqual(.function_expression, owner.tag);
                    try std.testing.expectEqual(entry.key_ptr.*, @backingInt(t.ast.readExtraNode(owner.data.extra, @import("../parser/ast.zig").FunctionExtra.body)));
                    continue;
                }
                try std.testing.expectEqual(.function_expression, t.ast.nodes.items[entry.key_ptr.*].tag);
                const physical_parent = utils.expectedScope(t.ast, output, &parents, &owners, entry.key_ptr.*).?;
                try std.testing.expectEqual(physical_parent, editor.scopes.items[storage.toIndex()].parent);
                actual_owners += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), actual_owners);
            var reads: usize = 0;
            for (editor.references.items) |reference| {
                if (@backingInt(reference.symbol_id) != id or reference.flags.declare) continue;
                if (!parents.contains(@backingInt(reference.node_index))) continue;
                const expected = utils.expectedScope(t.ast, output, &parents, &owners, @backingInt(reference.node_index)).?;
                try std.testing.expectEqual(expected, reference.scope_id);
                var ancestor = reference.scope_id;
                var hops: usize = 0;
                while (ancestor != storage and !ancestor.isNone() and hops < editor.scopes.items.len) : (hops += 1)
                    ancestor = editor.scopes.items[ancestor.toIndex()].parent;
                try std.testing.expectEqual(storage, ancestor);
                reads += 1;
            }
            try std.testing.expect(reads > 0);
        }
    }
}

fn sourceOwnerReport(a: std.mem.Allocator, tree: *const @import("../parser/ast.zig").Ast, root: @import("../parser/ast.zig").NodeIndex, scopes: []const @import("../semantic/scope.zig").Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32)) !@import("symbol_coverage.zig").ExactReport {
    const maps = try a.alloc(std.StringHashMapUnmanaged(usize), scopes.len);
    @memset(maps, .empty);
    const helpers: std.StringHashMapUnmanaged(usize) = .empty;
    const empty: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    return @import("symbol_coverage.zig").checkExact(a, tree, root, @intCast(tree.nodes.items.len), &.{}, &.{}, scopes, maps, owners, &.{}, &.{}, &helpers, &empty, &empty, &origins);
}

test "static block environment exact owner accepts only its canonical body alias" {
    const ast = @import("../parser/ast.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "class C{static{{}}static{}}");
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    const root = try parser.parse();
    var initial = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    try initial.analyze();
    var blocks: std.ArrayList(ast.NodeIndex) = .empty;
    for (parser.ast.nodes.items, 0..) |node, raw| if (node.tag == .static_block) try blocks.append(a, @fromBackingInt(@intCast(raw)));
    try std.testing.expectEqual(@as(usize, 2), blocks.items.len);
    const first_body = parser.ast.getNode(blocks.items[0]).data.unary.operand;
    const first_scope = initial.scope_owner_map.get(@backingInt(blocks.items[0])).?;
    const second_scope = initial.scope_owner_map.get(@backingInt(blocks.items[1])).?;
    initial.scopes.items[first_scope].kind = .function;
    const fake_function = try sourceOwnerReport(a, &parser.ast, root, initial.scopes.items, &initial.scope_owner_map);
    try std.testing.expect(fake_function.scope_owner_mismatch > 0);
    initial.scopes.items[first_scope].kind = .class_static_block;
    const positive = try sourceOwnerReport(a, &parser.ast, root, initial.scopes.items, &initial.scope_owner_map);
    try std.testing.expectEqual(@as(usize, 0), positive.scope_owner_mismatch);
    try std.testing.expectEqual(@as(usize, 0), positive.scope_owner_parent_mismatch);
    try std.testing.expectEqual(@as(usize, 0), positive.duplicate_scope_owner);
    try initial.scope_owner_map.put(a, @backingInt(first_body), second_scope);
    const wrong_owner = try sourceOwnerReport(a, &parser.ast, root, initial.scopes.items, &initial.scope_owner_map);
    try std.testing.expect(wrong_owner.scope_owner_mismatch > 0);
    _ = initial.scope_owner_map.remove(@backingInt(first_body));
    const missing = try sourceOwnerReport(a, &parser.ast, root, initial.scopes.items, &initial.scope_owner_map);
    try std.testing.expect(missing.scope_owner_mismatch > 0);
    try initial.scope_owner_map.put(a, @backingInt(first_body), first_scope);
    const first_list = parser.ast.getNode(first_body).data.list;
    const unrelated: ast.NodeIndex = @fromBackingInt(parser.ast.extra_data.items[first_list.start]);
    const unrelated_scope = initial.scope_owner_map.get(@backingInt(unrelated)).?;
    try initial.scope_owner_map.put(a, @backingInt(unrelated), first_scope);
    const stray = try sourceOwnerReport(a, &parser.ast, root, initial.scopes.items, &initial.scope_owner_map);
    try std.testing.expect(stray.scope_owner_mismatch > 0);
    try initial.scope_owner_map.put(a, @backingInt(unrelated), unrelated_scope);
    const restored = try sourceOwnerReport(a, &parser.ast, root, initial.scopes.items, &initial.scope_owner_map);
    try std.testing.expectEqual(@as(usize, 0), restored.scope_owner_mismatch);
}

const native_cases = [_][]const u8{
    "// 객체 rest 선언 — static 블록·형제 함수 같은 임시 이름·제너레이터·async·반복별 클로저 (#4790)\nconst out = [];\n// static 블록\nclass Holder {\n  static {\n    const { valueLong, ...otherLong } = { valueLong: 2, z: 3 };\n    Holder.v = valueLong + Object.keys(otherLong).length;\n  }\n}\nout.push(Holder.v);\n// 형제 함수가 같은 임시 변수 이름을 쓴다\nfunction one(o) {\n  const { keyLong, ...remLong } = o;\n  return keyLong + Object.keys(remLong).length;\n}\nfunction two(o) {\n  let { keyLong, ...remLong } = o;\n  keyLong += 10;\n  return keyLong + Object.keys(remLong).length;\n}\nout.push(one({ keyLong: 1, q: 1 }), two({ keyLong: 1 }));\n// 제너레이터·async 안\nfunction* gen(o) {\n  const { gLong, ...gRest } = o;\n  yield gLong;\n  yield Object.keys(gRest).join();\n}\nout.push([...gen({ gLong: 'g', m: 1, n: 2 })].join('|'));\nasync function run(o) {\n  const { aLong, ...aRest } = await o;\n  return aLong + Object.keys(aRest).length;\n}\n// 반복마다 새 바인딩 (클로저)\nconst fns = [];\nfor (const item of [\n  { idLong: 1, x: 1 },\n  { idLong: 2, x: 2 },\n]) {\n  const { idLong, ...extraLong } = item;\n  fns.push(() => idLong + extraLong.x);\n}\nout.push(fns.map((f) => f()).join());\nrun(Promise.resolve({ aLong: 5, b: 1 })).then((v) => {\n  out.push(v);\n  console.log(out.join(','));\n});\n",
    "// static 블록 안 객체 getter·중첩 클래스 메서드의 this (#4801)\nclass A {\n  static r = {};\n  static {\n    A.obj = {\n      get g() {\n        return this === A.obj;\n      },\n    };\n    A.C = class {\n      m() {\n        return this instanceof A.C;\n      }\n    };\n  }\n}\nconsole.log(A.obj.g, new A.C().m());\n",
    "class C{static{try{C=7}catch(error){console.log(error.name)}this.value=9}}console.log(C.value)",
    "class C{static{this.read=()=>C}}const saved=C;C=null;console.log(saved.read()===saved)",

    "class C{static{var value=3;this.a=()=>value}static{var value=9;this.b=()=>value}}console.log(C.a(),C.b())",
    "class C{static{let value=3;this.a=()=>value}static{let value=9;this.b=()=>value}}console.log(C.a(),C.b())",
    "class C{static{let value=3;function read(){return value}this.a=read}static{let value=9;function read(){return value}this.b=read}}console.log(C.a(),C.b())",
    "class C{static{console.log(value);{var value=3}this.a=()=>value}static{var value=9;this.b=()=>value}}console.log(C.a(),C.b())",
    "function outside(){return this===globalThis}class C{static{this.read=function(){return this}}}const read=C.read;console.log(read()===undefined,outside())",
    "class C{static{this.value=7;this.read=()=>this}}console.log(C.read()===C,C.value)",
    "class P{static value=7}class C extends P{static{this.value=super.value;this.read=()=>super.value}}console.log(C.read(),C.value)",
    "class C{static{this.value=new.target;this.read=()=>new.target}}console.log(C.value===undefined,C.read()===undefined)",
    "const events=[];class C{static{using resource={value:7,[Symbol.dispose](){events.push(\"disposed\")}};this.read=()=>resource.value;events.push(\"body\")}static{events.push(\"next\")}}console.log(events.join(\":\"),C.read())",
    "const events=[];try{class C{static{var value=3;events.push(value);throw 7}static{events.push(9)}}}catch(e){events.push(e)}console.log(events.join(\":\"))",
    "function make(value){return class C{static{var local=value;this.read=()=>local}}}const A=make(3),B=make(9);console.log(A.read(),B.read())",
    "class C{static{var value=3;this.a=()=>eval(\"value\")}static{var value=9;this.b=()=>eval(\"value\")}}console.log(C.a(),C.b())",
    "class C{static{this.value=read();function read(){return 3}function read(){return 9}}}console.log(C.value)",
    "class C{static{}static{this.value=7}}console.log(C.value)",
    "class C{#field;static{var value=3;this.a=()=>value}static{var value=9;this.b=()=>value}}console.log(C.a(),C.b())",
    "class C{static{var value=3;this.a=()=>value;class Inner{static{var value=7;this.read=()=>value}}this.b=Inner.read}}console.log(C.a(),C.b())",
};

test "static block environment native runtime preserves activation strictness and cleanup" {
    const Options = @import("options.zig").TransformOptions;
    for (native_cases, 0..) |source, case_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const reference = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(reference.term == .exited and reference.term.exited == 0);
        for ([_]@import("compat.zig").ESTarget{ .esnext, .es2022, .es2017, .es2015, .es5 }) |target| for ([_]bool{ false, true }) |minify| {
            errdefer std.debug.print("static body case={} target={s} minify={} source={s}\n", .{ case_index, @tagName(target), minify, source });
            const result = try @import("../transpile.zig").transpile(a, source, "input.cjs", .{
                .unsupported = Options.compat.fromESTarget(target),
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, reference.stdout, actual.stdout))
                std.debug.print("code={s}\nstdout={s}\nstderr={s}\n", .{ result.code, actual.stdout, actual.stderr });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(reference.stdout, actual.stdout);
        };
    }
}

const eval_cases = [_]struct { source: []const u8, rejected_when_moved: bool }{
    .{ .source = "class C{static{try{console.log(eval(\"arguments\"))}catch(e){console.log(e.name)}}}", .rejected_when_moved = true },
    .{ .source = "class C{static{console.log(eval(\"this\")===this)}}", .rejected_when_moved = true },
    .{ .source = "class P{static value=7}class C extends P{static{console.log(eval(\"super.value\"))}}", .rejected_when_moved = true },
    .{ .source = "class C{static{console.log(eval(\"new.target\")===undefined)}}", .rejected_when_moved = true },
    .{ .source = "const source=\"value\";class C{static{var value=7;console.log(eval(source))}}", .rejected_when_moved = true },
    .{ .source = "class C{static{console.log(eval(\"C\")===this)}}", .rejected_when_moved = true },
    .{ .source = "class C{static{console.log(eval(\"1+2\"))}}", .rejected_when_moved = false },
    .{ .source = "class C{static{var value=7;console.log(eval(\"value\"))}}", .rejected_when_moved = false },
};

test "static block environment dynamic eval keeps native syntax or reports existing typed boundary" {
    const Options = @import("options.zig").TransformOptions;
    for (eval_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const reference = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", case.source } });
        try std.testing.expect(reference.term == .exited and reference.term.exited == 0);
        for ([_]@import("compat.zig").ESTarget{ .esnext, .es2022, .es2017, .es2015, .es5 }) |target| for ([_]bool{ false, true }) |minify| {
            const unsupported = Options.compat.fromESTarget(target);
            const options: @import("../transpile.zig").TranspileOptions = .{ .unsupported = unsupported, .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify };
            if (unsupported.class_static_block and case.rejected_when_moved) {
                try std.testing.expectError(error.StaticInitializerDynamicScope, @import("../transpile.zig").transpile(a, case.source, "input.cjs", options));
                continue;
            }
            const output = try @import("../transpile.zig").transpile(a, case.source, "input.cjs", options);
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(reference.stdout, actual.stdout);
        };
    }
}
