const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const ast_walk = @import("../parser/ast_walk.zig");
const ConstValue = @import("../semantic/symbol.zig").ConstValue;
const minify_mod = @import("../transformer/minify.zig");
const profile = @import("../profile.zig");

fn constValueNode(ast: *Ast, cv: ConstValue) ?Node {
    return switch (cv.kind) {
        .true_, .false_ => blk: {
            const text = if (cv.kind == .true_) "true" else "false";
            const span = ast.addString(text) catch return null;
            break :blk .{
                .tag = .boolean_literal,
                .span = span,
                .data = .{ .none = 0 },
            };
        },
        .null_ => blk: {
            const span = ast.addString("null") catch return null;
            break :blk .{
                .tag = .null_literal,
                .span = span,
                .data = .{ .none = 0 },
            };
        },
        .number => blk: {
            if (cv.number_text.len == 0) break :blk null;
            const span = ast.addString(cv.number_text) catch return null;
            break :blk .{
                .tag = .numeric_literal,
                .span = span,
                .data = .{ .none = 0 },
            };
        },
        else => null,
    };
}

fn canMaterializeConstValue(cv: ConstValue) bool {
    return switch (cv.kind) {
        .true_, .false_, .null_ => true,
        .number => cv.number_text.len != 0,
        else => false,
    };
}

fn materializeValueForNode(
    ast: *const Ast,
    symbol_ids: []const ?u32,
    const_values: *const std.AutoHashMapUnmanaged(u32, ConstValue),
    forbidden: *const std.DynamicBitSet,
    eligible_reference_nodes: ?*const std.DynamicBitSet,
    raw: usize,
) ?ConstValue {
    if (raw >= ast.nodes.items.len or ast.nodes.items[raw].tag != .identifier_reference) return null;
    if (eligible_reference_nodes) |eligible| {
        if (raw >= eligible.capacity() or !eligible.isSet(raw)) return null;
    }
    if (raw >= symbol_ids.len or forbidden.isSet(raw)) return null;
    const symbol_id = symbol_ids[raw] orelse return null;
    const value = const_values.get(symbol_id) orelse return null;
    if (!canMaterializeConstValue(value)) return null;
    return value;
}

/// `materialize` 가 모듈마다 forbidden bitset + reachable 리스트를 매번 새로 만들지
/// 않도록 outer driver (tree_shaker post-pass) 가 보유하는 per-module 캐시.
///
/// 같은 모듈에 대해 numeric post-pass 가 forward/reverse × 최대 2 회 호출하면 inner
/// 가 4 번 도는데 — `forbidden` 은 AST shape 만 의존, `reachable` 도 마찬가지라
/// AST mutation (`tree_shaker.markAstMutatedAndResync`) 직전까지는 안전하게 재사용.
///
/// `materialize` 가 leaf identifier 노드를 leaf literal 로 바꾸는 in-place mutation 만
/// 하므로 `nodes.items.len` 도 변화 없음 → 같은 bitset 크기 그대로.
pub const Scratch = struct {
    allocator: std.mem.Allocator,
    /// per-module forbidden bitset. null = 아직 빌드 안 했거나 invalidate 직후.
    forbidden: []?std.DynamicBitSet,
    /// per-module reachable node 인덱스 리스트.
    reachable: []?[]u32,

    pub fn init(allocator: std.mem.Allocator, mod_count: usize) !Scratch {
        const forbidden = try allocator.alloc(?std.DynamicBitSet, mod_count);
        errdefer allocator.free(forbidden);
        for (forbidden) |*f| f.* = null;
        const reachable = try allocator.alloc(?[]u32, mod_count);
        errdefer allocator.free(reachable);
        for (reachable) |*r| r.* = null;
        return .{
            .allocator = allocator,
            .forbidden = forbidden,
            .reachable = reachable,
        };
    }

    pub fn deinit(self: *Scratch) void {
        for (self.forbidden) |*f| if (f.*) |*bs| bs.deinit();
        self.allocator.free(self.forbidden);
        for (self.reachable) |r| if (r) |slice| self.allocator.free(slice);
        self.allocator.free(self.reachable);
    }

    /// 모듈의 캐시를 다음 호출에서 재빌드하도록 해제. tree_shaker 가 AST mutation
    /// 후 호출 — `minifyAndResyncModule` / `applyNodeBufferCapabilityFacts` 양쪽
    /// 경로 공통 진입점인 `markAstMutatedAndResync` 한 곳에서.
    pub fn invalidate(self: *Scratch, mod_idx: usize) void {
        if (mod_idx >= self.forbidden.len) return;
        if (self.forbidden[mod_idx]) |*bs| {
            bs.deinit();
            self.forbidden[mod_idx] = null;
        }
        if (self.reachable[mod_idx]) |slice| {
            self.allocator.free(slice);
            self.reachable[mod_idx] = null;
        }
    }
};

pub const MaterializeProfile = struct {
    forbidden: ?profile.Category = null,
    reachable: ?profile.Category = null,
    replace: ?profile.Category = null,
};

pub const MaterializeResult = struct {
    changed: bool = false,
    needs_minify: bool = false,
    tracked_nodes_complete: bool = false,
};

/// Linker가 증명한 primitive constants를 AST read-site에 반영한다.
/// codegen-only 치환은 branch body refs를 줄이지 못하므로, minify/DCE 전 literal로
/// materialize해야 dead branch와 그 안의 imports가 다음 pass에서 사라질 수 있다.
pub fn materialize(
    allocator: std.mem.Allocator,
    ast: *Ast,
    symbol_ids: []const ?u32,
    const_values: *const std.AutoHashMapUnmanaged(u32, ConstValue),
) bool {
    return materializeWithScratch(allocator, ast, symbol_ids, const_values, null, 0, .{}).changed;
}

/// `materialize` + outer driver 가 forbidden/reachable 캐시 재사용. `scratch == null`
/// 이면 `materialize` 와 동일 (매 호출 빌드).
pub fn materializeWithScratch(
    allocator: std.mem.Allocator,
    ast: *Ast,
    symbol_ids: []const ?u32,
    const_values: *const std.AutoHashMapUnmanaged(u32, ConstValue),
    scratch: ?*Scratch,
    mod_idx: usize,
    profile_cats: MaterializeProfile,
) MaterializeResult {
    return materializeWithScratchDetailed(allocator, ast, symbol_ids, const_values, scratch, mod_idx, profile_cats, false, null, null);
}

/// `track_minify_need` 활성 시 치환된 read-site 가 minify/DCE 문맥인지 함께 반환한다.
/// 단순 call argument 같은 문맥은 metadata resync 만 필요하고 full minify 는 생략 가능하다.
pub fn materializeWithScratchDetailed(
    allocator: std.mem.Allocator,
    ast: *Ast,
    symbol_ids: []const ?u32,
    const_values: *const std.AutoHashMapUnmanaged(u32, ConstValue),
    scratch: ?*Scratch,
    mod_idx: usize,
    profile_cats: MaterializeProfile,
    track_minify_need: bool,
    eligible_reference_nodes: ?*const std.DynamicBitSet,
    tracked_nodes: ?*std.ArrayList(ast_mod.NodeIndex),
) MaterializeResult {
    if (const_values.count() == 0) return .{};

    // forbidden 확보: 캐시 hit 면 재사용, miss 면 빌드 후 캐시 또는 단발성 사용.
    var owned_forbidden: ?std.DynamicBitSet = null;
    defer if (owned_forbidden) |*bs| bs.deinit();
    const forbidden_ptr: *const std.DynamicBitSet = blk: {
        if (scratch) |s| if (mod_idx < s.forbidden.len) {
            if (s.forbidden[mod_idx]) |*cached| break :blk cached;
            var bs = std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len) catch return .{};
            var forbidden_scope = profile.beginMaybe(profile_cats.forbidden);
            defer forbidden_scope.end();
            minify_mod.markForbiddenInlineSites(ast, &bs);
            s.forbidden[mod_idx] = bs;
            break :blk &s.forbidden[mod_idx].?;
        };
        owned_forbidden = std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len) catch return .{};
        var forbidden_scope = profile.beginMaybe(profile_cats.forbidden);
        defer forbidden_scope.end();
        minify_mod.markForbiddenInlineSites(ast, &owned_forbidden.?);
        break :blk &owned_forbidden.?;
    };

    // transformer 가 만든 orphan 노드까지 스캔하지 않도록 reachable 만 순회 (#1797 패턴).
    var owned_reachable: ?[]u32 = null;
    defer if (owned_reachable) |slice| allocator.free(slice);
    const reachable: []const u32 = blk: {
        if (scratch) |s| if (mod_idx < s.reachable.len) {
            if (s.reachable[mod_idx]) |cached| break :blk cached;
            var reachable_scope = profile.beginMaybe(profile_cats.reachable);
            defer reachable_scope.end();
            const built = ast_walk.collectReachableNodeIndices(allocator, ast) catch return .{};
            s.reachable[mod_idx] = built;
            break :blk built;
        };
        var reachable_scope = profile.beginMaybe(profile_cats.reachable);
        defer reachable_scope.end();
        owned_reachable = ast_walk.collectReachableNodeIndices(allocator, ast) catch return .{};
        break :blk owned_reachable.?;
    };

    var sensitive_refs: ?std.DynamicBitSet = null;
    defer if (sensitive_refs) |*bs| bs.deinit();
    if (track_minify_need) {
        sensitive_refs = std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len) catch null;
        if (sensitive_refs) |*bs| markMinifySensitiveIdentifierRefs(ast, reachable, bs);
    }

    var changed = false;
    var needs_minify = false;
    const tracked_nodes_complete = tracked_nodes != null;
    {
        var replace_scope = profile.beginMaybe(profile_cats.replace);
        defer replace_scope.end();

        for (reachable) |ni| {
            const i: usize = @intCast(ni);
            const cv = materializeValueForNode(
                ast,
                symbol_ids,
                const_values,
                forbidden_ptr,
                eligible_reference_nodes,
                i,
            ) orelse continue;
            if (tracked_nodes) |nodes| {
                // Reserve before this edit. If OOM prevents the next slot, stop
                // materializing; every earlier mutation already has an exact
                // tracked NodeIndex, so the retained graph remains usable.
                nodes.ensureUnusedCapacity(allocator, 1) catch break;
            }
            const replacement = constValueNode(ast, cv) orelse continue;
            if (tracked_nodes) |nodes| nodes.appendAssumeCapacity(@fromBackingInt(@intCast(ni)));
            if (track_minify_need and !needs_minify) {
                needs_minify = if (sensitive_refs) |*bs|
                    i >= bs.capacity() or bs.isSet(i)
                else
                    true;
            }
            ast.nodes.items[i] = replacement;
            changed = true;
        }
    }
    return .{
        .changed = changed,
        .needs_minify = needs_minify,
        .tracked_nodes_complete = tracked_nodes_complete,
    };
}

fn isMinifySensitiveParent(tag: Node.Tag) bool {
    return switch (tag) {
        .unary_expression,
        .binary_expression,
        .logical_expression,
        .conditional_expression,
        .sequence_expression,
        .parenthesized_expression,
        .expression_statement,
        .if_statement,
        .switch_statement,
        .switch_case,
        .while_statement,
        .do_while_statement,
        .variable_declarator,
        => true,
        else => false,
    };
}

fn markMinifySensitiveIdentifierRefs(
    ast: *const Ast,
    reachable: []const u32,
    sensitive_refs: *std.DynamicBitSet,
) void {
    for (reachable) |parent_ni| {
        const parent_i: usize = @intCast(parent_ni);
        if (parent_i >= ast.nodes.items.len) continue;
        const parent = ast.nodes.items[parent_i];
        if (!isMinifySensitiveParent(parent.tag)) continue;

        var it = ast_walk.children(ast, parent);
        while (it.next()) |child| {
            if (child.isNone()) continue;
            const child_i = @backingInt(child);
            if (child_i >= ast.nodes.items.len or child_i >= sensitive_refs.capacity()) continue;
            if (ast.nodes.items[child_i].tag == .identifier_reference) {
                sensitive_refs.set(child_i);
            }
        }
    }
}

test "constant_facts: numeric const value materializes to numeric literal node" {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "console.log(n + 2);");
    defer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var symbol_ids = try allocator.alloc(?u32, parser.ast.nodes.items.len);
    defer allocator.free(symbol_ids);
    @memset(symbol_ids, null);

    var target_idx: ?usize = null;
    for (parser.ast.nodes.items, 0..) |node, i| {
        if (node.tag == .identifier_reference and std.mem.eql(u8, parser.ast.getText(node.span), "n")) {
            symbol_ids[i] = 7;
            target_idx = i;
            break;
        }
    }
    const idx = target_idx orelse return error.MissingIdentifier;

    var const_values: std.AutoHashMapUnmanaged(u32, ConstValue) = .empty;
    defer const_values.deinit(allocator);
    try const_values.put(allocator, 7, .{ .kind = .number, .number_text = "123" });

    const result = materializeWithScratchDetailed(
        allocator,
        &parser.ast,
        symbol_ids,
        &const_values,
        null,
        0,
        .{},
        false,
        null,
        null,
    );
    try std.testing.expect(result.changed);
    try std.testing.expect(!result.tracked_nodes_complete);
    const node = parser.ast.nodes.items[idx];
    try std.testing.expectEqual(Node.Tag.numeric_literal, node.tag);
    try std.testing.expectEqualStrings("123", parser.ast.getText(node.span));
}

test "constant_facts: tracked materialization reserves and reports exact read nodes" {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "const n = 0; console.log(n, n);");
    defer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var symbol_ids = try allocator.alloc(?u32, parser.ast.nodes.items.len);
    defer allocator.free(symbol_ids);
    @memset(symbol_ids, null);

    var expected_nodes: std.ArrayList(ast_mod.NodeIndex) = .empty;
    defer expected_nodes.deinit(allocator);
    var binding_node: ?ast_mod.NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (!std.mem.eql(u8, parser.ast.getText(node.span), "n")) continue;
        symbol_ids[raw] = 7;
        if (node.tag == .binding_identifier) binding_node = @fromBackingInt(@as(u32, @intCast(raw)));
        if (node.tag != .identifier_reference) continue;
        try expected_nodes.append(allocator, @fromBackingInt(@as(u32, @intCast(raw))));
    }
    try std.testing.expectEqual(@as(usize, 2), expected_nodes.items.len);
    const expected_binding = binding_node orelse return error.MissingBindingIdentifier;

    var const_values: std.AutoHashMapUnmanaged(u32, ConstValue) = .empty;
    defer const_values.deinit(allocator);
    try const_values.put(allocator, 7, .{ .kind = .number, .number_text = "123" });

    var tracked_nodes: std.ArrayList(ast_mod.NodeIndex) = .empty;
    defer tracked_nodes.deinit(allocator);
    const result = materializeWithScratchDetailed(
        allocator,
        &parser.ast,
        symbol_ids,
        &const_values,
        null,
        0,
        .{},
        false,
        null,
        &tracked_nodes,
    );
    try std.testing.expect(result.changed);
    try std.testing.expect(result.tracked_nodes_complete);
    try std.testing.expectEqual(expected_nodes.items.len, tracked_nodes.items.len);
    for (expected_nodes.items) |expected| {
        var matches: usize = 0;
        for (tracked_nodes.items) |tracked| if (tracked == expected) {
            matches += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), matches);
        try std.testing.expectEqual(Node.Tag.numeric_literal, parser.ast.getNode(expected).tag);
    }
    try std.testing.expectEqual(Node.Tag.binding_identifier, parser.ast.getNode(expected_binding).tag);
}

test "constant_facts: eligibility and forbidden filters gate exact read tracking" {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "console.log(n, n, n);");
    defer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var symbol_ids = try allocator.alloc(?u32, parser.ast.nodes.items.len);
    defer allocator.free(symbol_ids);
    @memset(symbol_ids, null);
    var references: [3]ast_mod.NodeIndex = undefined;
    var reference_count: usize = 0;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .identifier_reference or !std.mem.eql(u8, parser.ast.getText(node.span), "n")) continue;
        symbol_ids[raw] = 7;
        references[reference_count] = @fromBackingInt(@as(u32, @intCast(raw)));
        reference_count += 1;
    }
    try std.testing.expectEqual(references.len, reference_count);

    var const_values: std.AutoHashMapUnmanaged(u32, ConstValue) = .empty;
    defer const_values.deinit(allocator);
    try const_values.put(allocator, 7, .{ .kind = .number, .number_text = "123" });

    var scratch = try Scratch.init(allocator, 1);
    defer scratch.deinit();
    scratch.forbidden[0] = try std.DynamicBitSet.initEmpty(allocator, parser.ast.nodes.items.len);
    scratch.forbidden[0].?.set(@backingInt(references[0]));
    scratch.reachable[0] = try ast_walk.collectReachableNodeIndices(allocator, &parser.ast);

    var eligible = try std.DynamicBitSet.initEmpty(allocator, parser.ast.nodes.items.len);
    defer eligible.deinit();
    eligible.set(@backingInt(references[0]));
    eligible.set(@backingInt(references[1]));

    var tracked_nodes: std.ArrayList(ast_mod.NodeIndex) = .empty;
    defer tracked_nodes.deinit(allocator);
    const result = materializeWithScratchDetailed(
        allocator,
        &parser.ast,
        symbol_ids,
        &const_values,
        &scratch,
        0,
        .{},
        false,
        &eligible,
        &tracked_nodes,
    );

    try std.testing.expect(result.changed);
    try std.testing.expect(result.tracked_nodes_complete);
    try std.testing.expectEqual(@as(usize, 1), tracked_nodes.items.len);
    try std.testing.expectEqual(references[1], tracked_nodes.items[0]);
    try std.testing.expectEqual(Node.Tag.identifier_reference, parser.ast.getNode(references[0]).tag);
    try std.testing.expectEqual(Node.Tag.numeric_literal, parser.ast.getNode(references[1]).tag);
    try std.testing.expectEqualStrings("123", parser.ast.getText(parser.ast.getNode(references[1]).span));
    try std.testing.expectEqual(Node.Tag.identifier_reference, parser.ast.getNode(references[2]).tag);
}

test "constant_facts: unsupported const values do not reserve tracking slots" {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    const allocator = std.testing.allocator;
    const unsupported_values = [_]ConstValue{
        .{ .kind = .none },
        .{ .kind = .undefined_ },
        .{ .kind = .number, .number_text = "" },
    };

    for (unsupported_values) |value| {
        var scanner = try Scanner.init(allocator, "console.log(n);");
        defer scanner.deinit();
        var parser = Parser.init(allocator, &scanner);
        defer parser.deinit();
        _ = try parser.parse();

        var symbol_ids = try allocator.alloc(?u32, parser.ast.nodes.items.len);
        defer allocator.free(symbol_ids);
        @memset(symbol_ids, null);
        var reference: ?ast_mod.NodeIndex = null;
        for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag == .identifier_reference and std.mem.eql(u8, parser.ast.getText(node.span), "n")) {
                symbol_ids[raw] = 7;
                reference = @fromBackingInt(@as(u32, @intCast(raw)));
                break;
            }
        }
        const expected_reference = reference orelse return error.MissingIdentifier;

        var const_values: std.AutoHashMapUnmanaged(u32, ConstValue) = .empty;
        defer const_values.deinit(allocator);
        try const_values.put(allocator, 7, value);

        var scratch = try Scratch.init(allocator, 1);
        defer scratch.deinit();
        scratch.forbidden[0] = try std.DynamicBitSet.initEmpty(allocator, parser.ast.nodes.items.len);
        scratch.reachable[0] = try ast_walk.collectReachableNodeIndices(allocator, &parser.ast);

        var tracked_nodes: std.ArrayList(ast_mod.NodeIndex) = .empty;
        defer tracked_nodes.deinit(allocator);
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        const result = materializeWithScratchDetailed(
            failing.allocator(),
            &parser.ast,
            symbol_ids,
            &const_values,
            &scratch,
            0,
            .{},
            false,
            null,
            &tracked_nodes,
        );

        try std.testing.expect(!result.changed);
        try std.testing.expect(result.tracked_nodes_complete);
        try std.testing.expect(!failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), tracked_nodes.items.len);
        try std.testing.expectEqual(Node.Tag.identifier_reference, parser.ast.getNode(expected_reference).tag);
    }
}

test "constant_facts: first tracking reservation OOM leaves AST unchanged" {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "console.log(n, n);");
    defer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var symbol_ids = try allocator.alloc(?u32, parser.ast.nodes.items.len);
    defer allocator.free(symbol_ids);
    @memset(symbol_ids, null);
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .identifier_reference and std.mem.eql(u8, parser.ast.getText(node.span), "n"))
            symbol_ids[raw] = 7;
    }

    var const_values: std.AutoHashMapUnmanaged(u32, ConstValue) = .empty;
    defer const_values.deinit(allocator);
    try const_values.put(allocator, 7, .{ .kind = .number, .number_text = "123" });

    var scratch = try Scratch.init(allocator, 1);
    defer scratch.deinit();
    scratch.forbidden[0] = try std.DynamicBitSet.initEmpty(allocator, parser.ast.nodes.items.len);
    scratch.reachable[0] = try ast_walk.collectReachableNodeIndices(allocator, &parser.ast);

    const before_nodes = try allocator.dupe(Node, parser.ast.nodes.items);
    defer allocator.free(before_nodes);
    const before_extra = try allocator.dupe(u32, parser.ast.extra_data.items);
    defer allocator.free(before_extra);
    const before_strings = try allocator.dupe(u8, parser.ast.string_table.items);
    defer allocator.free(before_strings);

    var tracked_nodes: std.ArrayList(ast_mod.NodeIndex) = .empty;
    defer tracked_nodes.deinit(allocator);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const result = materializeWithScratchDetailed(
        failing.allocator(),
        &parser.ast,
        symbol_ids,
        &const_values,
        &scratch,
        0,
        .{},
        false,
        null,
        &tracked_nodes,
    );

    try std.testing.expect(!result.changed);
    try std.testing.expect(result.tracked_nodes_complete);
    try std.testing.expectEqual(@as(usize, 0), tracked_nodes.items.len);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(before_nodes), std.mem.sliceAsBytes(parser.ast.nodes.items));
    try std.testing.expectEqualDeep(before_extra, parser.ast.extra_data.items);
    try std.testing.expectEqualSlices(u8, before_strings, parser.ast.string_table.items);
}

fn expectPartialTrackingOom(
    allocator: std.mem.Allocator,
    source: []const u8,
    successful_edits: usize,
) !void {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var symbol_ids = try allocator.alloc(?u32, parser.ast.nodes.items.len);
    defer allocator.free(symbol_ids);
    @memset(symbol_ids, null);
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .identifier_reference and std.mem.eql(u8, parser.ast.getText(node.span), "n"))
            symbol_ids[raw] = 7;
    }

    var const_values: std.AutoHashMapUnmanaged(u32, ConstValue) = .empty;
    defer const_values.deinit(allocator);
    try const_values.put(allocator, 7, .{ .kind = .number, .number_text = "123" });

    var scratch = try Scratch.init(allocator, 1);
    defer scratch.deinit();
    scratch.forbidden[0] = try std.DynamicBitSet.initEmpty(allocator, parser.ast.nodes.items.len);
    scratch.reachable[0] = try ast_walk.collectReachableNodeIndices(allocator, &parser.ast);

    var expected_nodes: std.ArrayList(ast_mod.NodeIndex) = .empty;
    defer expected_nodes.deinit(allocator);
    for (scratch.reachable[0].?) |raw| {
        const i: usize = @intCast(raw);
        if (i >= symbol_ids.len or symbol_ids[i] != 7) continue;
        if (parser.ast.nodes.items[i].tag != .identifier_reference) continue;
        if (!std.mem.eql(u8, parser.ast.getText(parser.ast.nodes.items[i].span), "n")) continue;
        try expected_nodes.append(allocator, @fromBackingInt(raw));
    }
    try std.testing.expect(expected_nodes.items.len > successful_edits);

    const before_string_table_len = parser.ast.string_table.items.len;
    const before_string_intern_hits = parser.ast.string_intern_hits;
    const before_string_intern_misses = parser.ast.string_intern_misses;

    var tracked_nodes: std.ArrayList(ast_mod.NodeIndex) = .empty;
    defer tracked_nodes.deinit(allocator);
    try tracked_nodes.ensureTotalCapacityPrecise(allocator, successful_edits + 1);
    try tracked_nodes.append(allocator, .none);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const result = materializeWithScratchDetailed(
        failing.allocator(),
        &parser.ast,
        symbol_ids,
        &const_values,
        &scratch,
        0,
        .{},
        false,
        null,
        &tracked_nodes,
    );

    try std.testing.expectEqual(successful_edits != 0, result.changed);
    try std.testing.expect(result.tracked_nodes_complete);
    try std.testing.expectEqual(successful_edits + 1, tracked_nodes.items.len);
    try std.testing.expectEqual(ast_mod.NodeIndex.none, tracked_nodes.items[0]);

    for (expected_nodes.items, 0..) |expected, index| {
        const node = parser.ast.getNode(expected);
        if (index < successful_edits) {
            try std.testing.expectEqual(Node.Tag.numeric_literal, node.tag);
            try std.testing.expectEqualStrings("123", parser.ast.getText(node.span));
            try std.testing.expectEqual(expected, tracked_nodes.items[index + 1]);
        } else {
            try std.testing.expectEqual(Node.Tag.identifier_reference, node.tag);
            try std.testing.expectEqualStrings("n", parser.ast.getText(node.span));
        }
    }

    const expected_intern_misses: u32 = if (successful_edits == 0) 0 else 1;
    const expected_intern_hits: u32 = if (successful_edits == 0) 0 else @intCast(successful_edits - 1);
    const expected_string_table_len = before_string_table_len + (if (successful_edits == 0) 0 else "123".len);
    try std.testing.expectEqual(expected_string_table_len, parser.ast.string_table.items.len);
    try std.testing.expectEqual(before_string_intern_hits + expected_intern_hits, parser.ast.string_intern_hits);
    try std.testing.expectEqual(before_string_intern_misses + expected_intern_misses, parser.ast.string_intern_misses);
}

test "constant_facts: later tracking reservation OOM keeps partial edits exactly tracked across ten input shapes" {
    const source_forms = [_][]const u8{
        "console.log(n, n, n);",
        "console.log([n, n, n]);",
        "console.log(({ a: n, b: n, c: n }));",
        "console.log(Math.max(n, n, n));",
        "console.log(n ? n : n, n);",
        "console.log(+n, n + n);",
        "console.log(n && n, n);",
        "if (n) console.log(n, n);",
        "console.log((n, n), n);",
        "switch (n) { case n: console.log(n); break; }",
    };

    for (source_forms, 0..) |source, index| {
        try expectPartialTrackingOom(std.testing.allocator, source, 1 + index % 2);
    }
}

test "constant_facts: numeric const value does not replace object shorthand key" {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, "const obj = { n };");
    defer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var symbol_ids = try allocator.alloc(?u32, parser.ast.nodes.items.len);
    defer allocator.free(symbol_ids);
    @memset(symbol_ids, null);

    var target_idx: ?usize = null;
    for (parser.ast.nodes.items, 0..) |node, i| {
        if (node.tag == .identifier_reference and std.mem.eql(u8, parser.ast.getText(node.span), "n")) {
            symbol_ids[i] = 7;
            target_idx = i;
            break;
        }
    }
    const idx = target_idx orelse return error.MissingIdentifier;

    var const_values: std.AutoHashMapUnmanaged(u32, ConstValue) = .empty;
    defer const_values.deinit(allocator);
    try const_values.put(allocator, 7, .{ .kind = .number, .number_text = "123" });

    try std.testing.expect(!materialize(allocator, &parser.ast, symbol_ids, &const_values));
    const node = parser.ast.nodes.items[idx];
    try std.testing.expectEqual(Node.Tag.identifier_reference, node.tag);
    try std.testing.expectEqualStrings("n", parser.ast.getText(node.span));
}

fn expectMaterializeMinifyNeed(source: []const u8, expected_needs_minify: bool) !void {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var symbol_ids = try allocator.alloc(?u32, parser.ast.nodes.items.len);
    defer allocator.free(symbol_ids);
    @memset(symbol_ids, null);

    for (parser.ast.nodes.items, 0..) |node, i| {
        if (node.tag == .identifier_reference and std.mem.eql(u8, parser.ast.getText(node.span), "n")) {
            symbol_ids[i] = 7;
            break;
        }
    }

    var const_values: std.AutoHashMapUnmanaged(u32, ConstValue) = .empty;
    defer const_values.deinit(allocator);
    try const_values.put(allocator, 7, .{ .kind = .number, .number_text = "123" });

    const result = materializeWithScratchDetailed(allocator, &parser.ast, symbol_ids, &const_values, null, 0, .{}, true, null, null);
    try std.testing.expect(result.changed);
    try std.testing.expectEqual(expected_needs_minify, result.needs_minify);
}

test "constant_facts: call argument numeric replacement does not require minify" {
    try expectMaterializeMinifyNeed("console.log(n);", false);
}

test "constant_facts: binary numeric replacement requires minify" {
    try expectMaterializeMinifyNeed("console.log(n + 2);", true);
}
