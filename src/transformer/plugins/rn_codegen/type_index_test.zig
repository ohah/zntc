//! type_index.zig 단위 테스트.
//!
//! 4 종 declaration 태그 인식 + export wrapper 처리 + 중복 이름 처리 검증.

const std = @import("std");
const Scanner = @import("../../../lexer/scanner.zig").Scanner;
const Parser = @import("../../../parser/parser.zig").Parser;
const type_index = @import("type_index.zig");

/// 소스를 파싱해서 program NodeIndex 반환. transformer 안 거침 — 타입 노드가
/// strip 되기 전 raw AST 가 필요.
const ParsedSource = struct {
    scanner: Scanner,
    parser: Parser,
    program: @import("../../../parser/ast.zig").NodeIndex,

    fn init(alloc: std.mem.Allocator, source: []const u8) !ParsedSource {
        var scanner = try Scanner.init(alloc, source);
        errdefer scanner.deinit();

        var parser = Parser.init(alloc, &scanner);
        errdefer parser.deinit();

        const program = try parser.parse();
        return .{ .scanner = scanner, .parser = parser, .program = program };
    }

    fn deinit(self: *ParsedSource) void {
        self.parser.deinit();
        self.scanner.deinit();
    }
};

/// build()를 호출하고 caller 가 deinit 한 번에 정리할 수 있도록 묶음.
const Indexed = struct {
    parsed: ParsedSource,
    index: type_index.TypeIndex,

    fn deinit(self: *Indexed, alloc: std.mem.Allocator) void {
        self.index.deinit(alloc);
        self.parsed.deinit();
    }
};

fn parseAndIndex(alloc: std.mem.Allocator, source: []const u8) !Indexed {
    var parsed = try ParsedSource.init(alloc, source);
    errdefer parsed.deinit();

    const index = try type_index.build(&parsed.parser.ast, parsed.program, alloc);
    return .{ .parsed = parsed, .index = index };
}

test "TypeIndex: TS type alias indexed" {
    var r = try parseAndIndex(std.testing.allocator,
        \\type Props = { color: string };
    );
    defer r.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), r.index.count());
    try std.testing.expect(r.index.get("Props") != null);
}

test "TypeIndex: TS interface indexed" {
    var r = try parseAndIndex(std.testing.allocator,
        \\interface Props { color: string }
    );
    defer r.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), r.index.count());
    try std.testing.expect(r.index.get("Props") != null);
}

test "TypeIndex: Flow type alias indexed" {
    var r = try parseAndIndex(std.testing.allocator,
        \\// @flow
        \\type Props = {| color: string |};
    );
    defer r.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), r.index.count());
    try std.testing.expect(r.index.get("Props") != null);
}

test "TypeIndex: Flow interface indexed" {
    var r = try parseAndIndex(std.testing.allocator,
        \\// @flow
        \\interface Props { color: string }
    );
    defer r.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), r.index.count());
    try std.testing.expect(r.index.get("Props") != null);
}

test "TypeIndex: Flow opaque type indexed" {
    var r = try parseAndIndex(std.testing.allocator,
        \\// @flow
        \\opaque type Props = { color: string };
    );
    defer r.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), r.index.count());
    try std.testing.expect(r.index.get("Props") != null);
}

test "TypeIndex: export type alias is indexed" {
    // #2348 Phase 2 의 root-cause fix (`module.zig:885`) 이후 type-only declaration
    // 의 export wrapper 만 생략하고 decl 자체는 program 에 직접 추가됨.
    // import_scanner 는 export_named_declaration wrapper 부재 → has_esm_syntax 영향 X.
    var r = try parseAndIndex(std.testing.allocator,
        \\export type Props = { color: string };
    );
    defer r.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), r.index.count());
    try std.testing.expect(r.index.get("Props") != null);
}

test "TypeIndex: export interface is indexed" {
    var r = try parseAndIndex(std.testing.allocator,
        \\export interface Props { color: string }
    );
    defer r.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), r.index.count());
    try std.testing.expect(r.index.get("Props") != null);
}

test "TypeIndex: multiple declarations all indexed" {
    var r = try parseAndIndex(std.testing.allocator,
        \\type Props = { color: string };
        \\interface Events { onChange: () => void }
        \\type ViewProps = { width: number };
    );
    defer r.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), r.index.count());
    try std.testing.expect(r.index.get("Props") != null);
    try std.testing.expect(r.index.get("Events") != null);
    try std.testing.expect(r.index.get("ViewProps") != null);
}

test "TypeIndex: generic type alias indexed by name only" {
    var r = try parseAndIndex(std.testing.allocator,
        \\type Container<T> = { value: T };
    );
    defer r.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), r.index.count());
    try std.testing.expect(r.index.get("Container") != null);
}

test "TypeIndex: duplicate name keeps last definition" {
    var r = try parseAndIndex(std.testing.allocator,
        \\type Props = { a: string };
        \\type Props = { b: number };
    );
    defer r.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), r.index.count());

    // program 자식을 직접 훑어 마지막 type_alias_declaration("Props") 의 NodeIndex 를
    // 구한 뒤 인덱스가 그걸 가리키는지 확인.
    const ast = &r.parsed.parser.ast;
    const program = ast.getNode(r.parsed.program);
    const list = program.data.list;
    var expected_last: @import("../../../parser/ast.zig").NodeIndex = .none;
    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
        const stmt: @import("../../../parser/ast.zig").NodeIndex = @enumFromInt(raw);
        if (stmt == .none) continue;
        const node = ast.getNode(stmt);
        if (node.tag != .ts_type_alias_declaration) continue;
        const name_idx: @import("../../../parser/ast.zig").NodeIndex =
            @enumFromInt(ast.extra_data.items[node.data.extra]);
        const name = ast.getText(ast.getNode(name_idx).data.string_ref);
        if (std.mem.eql(u8, name, "Props")) expected_last = stmt;
    }

    try std.testing.expect(expected_last != .none);
    try std.testing.expectEqual(expected_last, r.index.get("Props").?);
}

test "TypeIndex: non-type top-level statements ignored" {
    var r = try parseAndIndex(std.testing.allocator,
        \\const x = 1;
        \\function foo() {}
        \\type Props = { color: string };
        \\class Bar {}
    );
    defer r.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), r.index.count());
    try std.testing.expect(r.index.get("Props") != null);
    try std.testing.expect(r.index.get("x") == null);
    try std.testing.expect(r.index.get("foo") == null);
    try std.testing.expect(r.index.get("Bar") == null);
}

test "TypeIndex: empty program produces empty index" {
    var r = try parseAndIndex(std.testing.allocator,
        \\
    );
    defer r.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), r.index.count());
    try std.testing.expect(r.index.get("Props") == null);
}

test "TypeIndex: nested type aliases not indexed" {
    // 함수 안의 type alias 는 top-level 이 아니라 인덱싱 안 됨.
    // (codegen spec 파일에선 이런 형태 안 나오지만 안전성 확인용)
    var r = try parseAndIndex(std.testing.allocator,
        \\function foo() {
        \\  type Inner = string;
        \\  return null;
        \\}
        \\type Outer = number;
    );
    defer r.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), r.index.count());
    try std.testing.expect(r.index.get("Outer") != null);
    try std.testing.expect(r.index.get("Inner") == null);
}
