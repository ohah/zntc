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

/// JSX 소스를 module + jsx 모드로 파싱한 Scanner+Parser 묶음.
/// `parser.ast` 의 text 슬라이스가 scanner 의 source 를 가리키므로 **parser 를 먼저** 해제한다
/// (caller 의 `defer` 2개로 나누면 등록 역순 때문에 scanner 가 먼저 죽는다).
/// 생성 중 실패해도 이미 만든 리소스를 여기서 정리한다 — caller 의 defer 는 아직 등록 전이다.
const ParsedJsx = struct {
    scanner: Scanner,
    parser: Parser,

    fn deinit(self: *ParsedJsx) void {
        self.parser.deinit();
        self.scanner.deinit();
    }

    fn ast(self: *ParsedJsx) *Ast {
        return &self.parser.ast;
    }
};

/// `out` 은 caller 스택에 있어야 한다 — `Parser` 가 `&out.scanner` 를 들고 있어서
/// 값 복사로 반환하면 포인터가 뜬다.
fn parseJsx(out: *ParsedJsx, source: []const u8) !void {
    out.scanner = try Scanner.init(std.testing.allocator, source);
    errdefer out.scanner.deinit();
    out.parser = Parser.init(std.testing.allocator, &out.scanner);
    errdefer out.parser.deinit();
    out.parser.is_module = true;
    out.parser.is_jsx = true;
    _ = try out.parser.parse();
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
    var p: ParsedJsx = undefined;
    try parseJsx(&p,
        \\import * as NS from "./ns";
        \\export const App = () => <NS.Root><NS.Button>hi</NS.Button></NS.Root>;
    );
    defer p.deinit();
    const ast = p.ast();
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
    var p: ParsedJsx = undefined;
    try parseJsx(&p,
        \\import * as NS from "./ns";
        \\export const App = () => <NS.Grp.Item>hi</NS.Grp.Item>;
    );
    defer p.deinit();
    const ast = p.ast();
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
    var p: ParsedJsx = undefined;
    try parseJsx(&p,
        \\import * as NS from "./ns";
        \\export const A = () => <NS.Root>hi</NS.Root>;
        \\export const B = () => <NS>x</NS>;
    );
    defer p.deinit();
    const ast = p.ast();

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
    var p: ParsedJsx = undefined;
    try parseJsx(&p,
        \\import * as div from "./ns";
        \\export const A = () => <div>{div.value}</div>;
    );
    defer p.deinit();
    const ast = p.ast();

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

test "isNamespaceUsedAsValue: JSX member object IS a value use — codegen can't rewrite preserved JSX (#4596)" {
    // ⚠️ 이 술어의 질문은 "namespace 객체 생성을 생략해도 되나"(force_inline) 다. JSX 가 원형으로
    // 남는 경로(`jsx_runtime = .preserve`)에서는 `codegen/jsx.zig::emitJsxMemberExpression` 이
    // `ns_member_rewrites` 를 보지 않아 `<NS.Root>` 의 `NS` 를 치환하지 못한다. 따라서 JSX 멤버의
    // object 를 "safe"(치환 가능) 로 세면 객체가 생성되지 않는데 출력엔 `<NS.Root>` 가 남아
    // **선언 없는 참조**가 된다. `NamespaceAccessIndex` 가 JSX 멤버를 색인하는 것과는 다른 질문 —
    // 색인은 "어떤 export 가 살아야 하나", 이 술어는 "객체를 생략해도 되나" 에 답한다.
    var p: ParsedJsx = undefined;
    try parseJsx(&p,
        \\import * as NS from "./ns";
        \\export const App = () => <NS.Root>hi</NS.Root>;
    );
    defer p.deinit();
    const ast = p.ast();

    const sids = try symbolIdsForJsxIdent(ast, "NS", 42);
    defer std.testing.allocator.free(sids);
    // NS 심볼이 실제로 심어졌는지 (안 심겼으면 단언이 공허).
    var planted: usize = 0;
    for (sids) |s| {
        if (s != null) planted += 1;
    }
    try std.testing.expect(planted >= 1);

    try std.testing.expect(ns_access.isNamespaceUsedAsValue(std.testing.allocator, ast, sids, 42));
}

test "isNamespaceUsedAsValue: bare JSX namespace tag is a value use (#4596)" {
    var p: ParsedJsx = undefined;
    try parseJsx(&p,
        \\import * as NS from "./ns";
        \\export const B = () => <NS>x</NS>;
    );
    defer p.deinit();
    const ast = p.ast();

    const sids = try symbolIdsForJsxIdent(ast, "NS", 42);
    defer std.testing.allocator.free(sids);

    try std.testing.expect(ns_access.isNamespaceUsedAsValue(std.testing.allocator, ast, sids, 42));
}
