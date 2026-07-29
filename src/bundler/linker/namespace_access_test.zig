//! `namespace_access.zig` 유닛 테스트 — JSX 태그 위치의 namespace 접근 색인 (#4596).
//!
//! 번들 end-to-end 테스트(`bundler_test/jsx.zig`)는 "증상이 사라졌는지" 를 보지만,
//! #4596 은 두 결함의 합이라 어느 한쪽만 되돌려도 증상이 안 나온다. 그래서 이 파일은
//! 색인 계층 하나만 떼어내 직접 단언한다 — 색인 브랜치가 지워지면 여기서 바로 실패한다.

const std = @import("std");
const Scanner = @import("../../lexer/scanner.zig").Scanner;
const Parser = @import("../../parser/parser.zig").Parser;
const ns_access = @import("namespace_access.zig");
const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const Tag = ast_mod.Node.Tag;

/// JSX 소스를 module + jsx 모드로 파싱. AST 는 `parser.ast` 소유 — caller 가 parser 를 살려둬야 한다.
fn parseJsx(parser: *Parser, scanner: *Scanner, source: []const u8) !void {
    scanner.* = try Scanner.init(std.testing.allocator, source);
    parser.* = Parser.init(std.testing.allocator, scanner);
    parser.is_module = true;
    parser.is_jsx = true;
    _ = try parser.parse();
}

/// 파싱이 실제로 JSX 노드를 만들었는지 — parse 가 조용히 실패하면 모든 단언이 공허해진다.
fn countTag(ast: *const Ast, tag: Tag) usize {
    var n: usize = 0;
    for (ast.nodes.items) |node| {
        if (node.tag == tag) n += 1;
    }
    return n;
}

test "NamespaceAccessIndex: JSX member tag (`<NS.Root>`) is indexed as a namespace member (#4596)" {
    var scanner: Scanner = undefined;
    var parser: Parser = undefined;
    try parseJsx(&parser, &scanner,
        \\import * as NS from "./ns";
        \\export const App = () => <NS.Root><NS.Button>hi</NS.Button></NS.Root>;
    );
    defer parser.deinit();
    defer scanner.deinit();
    const ast = &parser.ast;
    try std.testing.expect(countTag(ast, .jsx_member_expression) >= 2);

    var index = try ns_access.NamespaceAccessIndex.build(std.testing.allocator, ast);
    defer index.deinit(std.testing.allocator);

    var access = try ns_access.analyzeNamespaceAccessTextOnly(std.testing.allocator, ast, &index, "NS", null);
    defer access.deinit(std.testing.allocator);

    try std.testing.expectEqual(ns_access.NamespaceAccess.Kind.member_only, access.kind);
    try std.testing.expectEqual(@as(u32, 2), access.members.count());
    try std.testing.expect(access.members.contains("Root"));
    try std.testing.expect(access.members.contains("Button"));
}

test "NamespaceAccessIndex: nested JSX member chain records only the first hop (#4596)" {
    var scanner: Scanner = undefined;
    var parser: Parser = undefined;
    try parseJsx(&parser, &scanner,
        \\import * as NS from "./ns";
        \\export const App = () => <NS.Grp.Item>hi</NS.Grp.Item>;
    );
    defer parser.deinit();
    defer scanner.deinit();
    const ast = &parser.ast;
    try std.testing.expect(countTag(ast, .jsx_member_expression) >= 2);

    var index = try ns_access.NamespaceAccessIndex.build(std.testing.allocator, ast);
    defer index.deinit(std.testing.allocator);

    var access = try ns_access.analyzeNamespaceAccessTextOnly(std.testing.allocator, ast, &index, "NS", null);
    defer access.deinit(std.testing.allocator);

    // NS 의 export 는 `Grp` 뿐 — `Item` 은 Grp 객체의 프로퍼티지 NS 의 export 가 아니다.
    try std.testing.expectEqual(ns_access.NamespaceAccess.Kind.member_only, access.kind);
    try std.testing.expectEqual(@as(u32, 1), access.members.count());
    try std.testing.expect(access.members.contains("Grp"));
    try std.testing.expect(!access.members.contains("Item"));
}

test "NamespaceAccessIndex: bare JSX namespace tag (`<NS/>`) is an escape → opaque (#4596)" {
    var scanner: Scanner = undefined;
    var parser: Parser = undefined;
    try parseJsx(&parser, &scanner,
        \\import * as NS from "./ns";
        \\export const A = () => <NS.Root>hi</NS.Root>;
        \\export const B = () => <NS>x</NS>;
    );
    defer parser.deinit();
    defer scanner.deinit();
    const ast = &parser.ast;

    var index = try ns_access.NamespaceAccessIndex.build(std.testing.allocator, ast);
    defer index.deinit(std.testing.allocator);

    var access = try ns_access.analyzeNamespaceAccessTextOnly(std.testing.allocator, ast, &index, "NS", null);
    defer access.deinit(std.testing.allocator);

    // namespace 객체 자체가 factory 로 전달되므로 멤버 집합으로 좁힐 수 없다.
    try std.testing.expectEqual(ns_access.NamespaceAccess.Kind.@"opaque", access.kind);
    try std.testing.expectEqual(@as(u32, 0), access.members.count());
}

test "NamespaceAccessIndex: intrinsic tag (`<div>`) does not escape a same-named namespace (#4596)" {
    // 소문자 태그는 jsx_lowering 이 string literal 로 낮추므로 값 참조가 아니다.
    // 이름이 같다는 이유로 escape 로 세면 불필요하게 opaque 가 된다.
    var scanner: Scanner = undefined;
    var parser: Parser = undefined;
    try parseJsx(&parser, &scanner,
        \\import * as div from "./ns";
        \\export const A = () => <div>{div.value}</div>;
    );
    defer parser.deinit();
    defer scanner.deinit();
    const ast = &parser.ast;

    var index = try ns_access.NamespaceAccessIndex.build(std.testing.allocator, ast);
    defer index.deinit(std.testing.allocator);

    var access = try ns_access.analyzeNamespaceAccessTextOnly(std.testing.allocator, ast, &index, "div", null);
    defer access.deinit(std.testing.allocator);

    try std.testing.expectEqual(ns_access.NamespaceAccess.Kind.member_only, access.kind);
    try std.testing.expect(access.members.contains("value"));
}

/// `text` 인 jsx_identifier 노드 전부에 `sym` 을 심은 symbol_ids 배열.
fn symbolIdsForJsxIdent(ast: *const Ast, text: []const u8, sym: u32) ![]?u32 {
    const sids = try std.testing.allocator.alloc(?u32, ast.nodes.items.len);
    @memset(sids, null);
    for (ast.nodes.items, 0..) |node, i| {
        if (node.tag != .jsx_identifier) continue;
        if (std.mem.eql(u8, ast.getText(node.span), text)) sids[i] = sym;
    }
    return sids;
}

test "isNamespaceUsedAsValue: JSX member object is not a value use (#4596)" {
    // 형제 술어 정합 — 색인은 member_only 로 보는데 이 술어만 "값으로 escape" 라고 답하면
    // 같은 파일의 두 분석기가 동일 입력에 대해 불일치한다 (모듈 doc 불변식 위반).
    var scanner: Scanner = undefined;
    var parser: Parser = undefined;
    try parseJsx(&parser, &scanner,
        \\import * as NS from "./ns";
        \\export const App = () => <NS.Root>hi</NS.Root>;
    );
    defer parser.deinit();
    defer scanner.deinit();
    const ast = &parser.ast;

    const sids = try symbolIdsForJsxIdent(ast, "NS", 42);
    defer std.testing.allocator.free(sids);
    // NS 심볼이 실제로 심어졌는지 (안 심겼으면 단언이 공허).
    var planted: usize = 0;
    for (sids) |s| {
        if (s != null) planted += 1;
    }
    try std.testing.expect(planted >= 1);

    try std.testing.expect(!ns_access.isNamespaceUsedAsValue(std.testing.allocator, ast, sids, 42));
}

test "isNamespaceUsedAsValue: bare JSX namespace tag is a value use (#4596)" {
    var scanner: Scanner = undefined;
    var parser: Parser = undefined;
    try parseJsx(&parser, &scanner,
        \\import * as NS from "./ns";
        \\export const B = () => <NS>x</NS>;
    );
    defer parser.deinit();
    defer scanner.deinit();
    const ast = &parser.ast;

    const sids = try symbolIdsForJsxIdent(ast, "NS", 42);
    defer std.testing.allocator.free(sids);

    try std.testing.expect(ns_access.isNamespaceUsedAsValue(std.testing.allocator, ast, sids, 42));
}
