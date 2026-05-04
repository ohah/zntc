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
    return materializeWithScratchDetailed(allocator, ast, symbol_ids, const_values, scratch, mod_idx, profile_cats, false);
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
    {
        var replace_scope = profile.beginMaybe(profile_cats.replace);
        defer replace_scope.end();

        for (reachable) |ni| {
            const i: usize = @intCast(ni);
            const node = ast.nodes.items[i];
            if (node.tag != .identifier_reference) continue;
            if (i >= symbol_ids.len) continue;
            if (forbidden_ptr.isSet(i)) continue;
            const sym_id = symbol_ids[i] orelse continue;
            const cv = const_values.get(sym_id) orelse continue;
            const replacement = constValueNode(ast, cv) orelse continue;
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
    return .{ .changed = changed, .needs_minify = needs_minify };
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
            const child_i = @intFromEnum(child);
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

    var const_values: std.AutoHashMapUnmanaged(u32, ConstValue) = .{};
    defer const_values.deinit(allocator);
    try const_values.put(allocator, 7, .{ .kind = .number, .number_text = "123" });

    try std.testing.expect(materialize(allocator, &parser.ast, symbol_ids, &const_values));
    const node = parser.ast.nodes.items[idx];
    try std.testing.expectEqual(Node.Tag.numeric_literal, node.tag);
    try std.testing.expectEqualStrings("123", parser.ast.getText(node.span));
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

    var const_values: std.AutoHashMapUnmanaged(u32, ConstValue) = .{};
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

    var const_values: std.AutoHashMapUnmanaged(u32, ConstValue) = .{};
    defer const_values.deinit(allocator);
    try const_values.put(allocator, 7, .{ .kind = .number, .number_text = "123" });

    const result = materializeWithScratchDetailed(allocator, &parser.ast, symbol_ids, &const_values, null, 0, .{}, true);
    try std.testing.expect(result.changed);
    try std.testing.expectEqual(expected_needs_minify, result.needs_minify);
}

test "constant_facts: call argument numeric replacement does not require minify" {
    try expectMaterializeMinifyNeed("console.log(n);", false);
}

test "constant_facts: binary numeric replacement requires minify" {
    try expectMaterializeMinifyNeed("console.log(n + 2);", true);
}
