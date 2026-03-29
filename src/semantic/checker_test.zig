const std = @import("std");
const checker = @import("checker.zig");
const checkDuplicateConstructors = checker.checkDuplicateConstructors;
const checkPrivateNameStaticConflict = checker.checkPrivateNameStaticConflict;
const checkObjectDuplicateProto = checker.checkObjectDuplicateProto;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const Parser = @import("../parser/parser.zig").Parser;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const SemanticAnalyzer = @import("analyzer.zig").SemanticAnalyzer;

test "checker: duplicate constructor is error" {
    var scanner = try Scanner.init(std.testing.allocator, "class C { constructor() {} constructor() {} }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var errs: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (errs.items) |e| std.testing.allocator.free(e.message);
        errs.deinit(std.testing.allocator);
    }

    // class body를 찾아서 검사
    // AST 마지막 노드는 program, 그 안에 class_declaration이 있음
    const ast = &parser.ast;
    for (ast.nodes.items) |node| {
        if (node.tag == .class_body) {
            try checkDuplicateConstructors(ast, node.data.list, &errs, std.testing.allocator);
            break;
        }
    }

    try std.testing.expect(errs.items.len > 0);
}

test "checker: single constructor is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "class C { constructor() {} foo() {} }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(std.testing.allocator);

    const ast = &parser.ast;
    for (ast.nodes.items) |node| {
        if (node.tag == .class_body) {
            try checkDuplicateConstructors(ast, node.data.list, &errs, std.testing.allocator);
            break;
        }
    }

    try std.testing.expect(errs.items.len == 0);
}

test "checker: static/instance private name conflict is error" {
    var scanner = try Scanner.init(std.testing.allocator, "class C { set #f(v) {} static get #f() {} }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var errs: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (errs.items) |e| std.testing.allocator.free(e.message);
        errs.deinit(std.testing.allocator);
    }

    const ast = &parser.ast;
    for (ast.nodes.items) |node| {
        if (node.tag == .class_body) {
            try checkPrivateNameStaticConflict(ast, node.data.list, &errs, std.testing.allocator);
            break;
        }
    }

    try std.testing.expect(errs.items.len > 0);
}

test "checker: same static private getter+setter is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "class C { static get #f() {} static set #f(v) {} }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(std.testing.allocator);

    const ast = &parser.ast;
    for (ast.nodes.items) |node| {
        if (node.tag == .class_body) {
            try checkPrivateNameStaticConflict(ast, node.data.list, &errs, std.testing.allocator);
            break;
        }
    }

    try std.testing.expect(errs.items.len == 0);
}

test "checker: duplicate __proto__ is error" {
    var scanner = try Scanner.init(std.testing.allocator, "var o = { __proto__: null, __proto__: null };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var errs: std.ArrayList(Diagnostic) = .empty;
    defer {
        for (errs.items) |e| std.testing.allocator.free(e.message);
        errs.deinit(std.testing.allocator);
    }

    const ast = &parser.ast;
    for (ast.nodes.items) |node| {
        if (node.tag == .object_expression) {
            try checkObjectDuplicateProto(ast, node.data.list, &errs, std.testing.allocator);
            break;
        }
    }

    try std.testing.expect(errs.items.len > 0);
}

test "checker: single __proto__ is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "var o = { __proto__: null, x: 1 };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var errs: std.ArrayList(Diagnostic) = .empty;
    defer errs.deinit(std.testing.allocator);

    const ast = &parser.ast;
    for (ast.nodes.items) |node| {
        if (node.tag == .object_expression) {
            try checkObjectDuplicateProto(ast, node.data.list, &errs, std.testing.allocator);
            break;
        }
    }

    try std.testing.expect(errs.items.len == 0);
}

test "checker: duplicate arrow params is error" {
    var scanner = try Scanner.init(std.testing.allocator, "var f = (x, x) => x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "checker: duplicate method params is error" {
    var scanner = try Scanner.init(std.testing.allocator, "class C { foo(a, a) {} }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "checker: destructuring default values are not param names" {
    // { x = false, y = false } — false는 default value이지 param name이 아님
    // 파서 + semantic 모두 에러 없어야 함
    const cases = [_][]const u8{
        "const f = (s, { x = false, y = false } = {}) => s;",
        "const f = (s, { x = true, y = true } = {}) => s;",
        "const f = (s, { x = null, y = null } = {}) => s;",
        "const f = (s, { x = a, y = a } = {}) => s;",
        "const f = ({ x = foo, y = foo } = {}) => x;",
    };
    for (cases) |src| {
        var scanner = try Scanner.init(std.testing.allocator, src);
        defer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        defer parser.deinit();
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

        var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
        defer ana.deinit();
        try ana.analyze();
        try std.testing.expectEqual(@as(usize, 0), ana.errors.items.len);
    }
}
