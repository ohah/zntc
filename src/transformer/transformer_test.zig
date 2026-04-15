const std = @import("std");
const transformer_mod = @import("transformer.zig");
const Transformer = transformer_mod.Transformer;
const TransformOptions = transformer_mod.TransformOptions;
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const Ast = ast_mod.Ast;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;

test "Transformer: empty program" {
    const std_lib = @import("std");

    // 빈 프로그램: `program` 노드 하나만 있는 AST
    var old_ast = Ast.init(std_lib.testing.allocator, "");
    defer old_ast.deinit();

    const empty_list = try old_ast.addNodeList(&.{});
    _ = try old_ast.addNode(.{
        .tag = .program,
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .list = empty_list },
    });

    var t = try Transformer.init(std_lib.testing.allocator, &old_ast, .{});
    defer t.deinit();

    const root = try t.transform();
    const result = t.ast.getNode(root);

    try std_lib.testing.expectEqual(Tag.program, result.tag);
    try std_lib.testing.expectEqual(@as(u32, 0), result.data.list.len);
}

test "Transformer: strip type alias declaration" {
    const std_lib = @import("std");

    // program → [type_alias_declaration]
    var old_ast = Ast.init(std_lib.testing.allocator, "type Foo = string;");
    defer old_ast.deinit();

    // type alias node
    const type_node = try old_ast.addNode(.{
        .tag = .ts_type_alias_declaration,
        .span = .{ .start = 0, .end = 18 },
        .data = .{ .none = 0 },
    });

    const list = try old_ast.addNodeList(&.{type_node});
    _ = try old_ast.addNode(.{
        .tag = .program,
        .span = .{ .start = 0, .end = 18 },
        .data = .{ .list = list },
    });

    var t = try Transformer.init(std_lib.testing.allocator, &old_ast, .{});
    defer t.deinit();

    const root = try t.transform();
    const result = t.ast.getNode(root);

    // type alias가 제거되어 빈 program
    try std_lib.testing.expectEqual(Tag.program, result.tag);
    try std_lib.testing.expectEqual(@as(u32, 0), result.data.list.len);
}

test "Transformer: preserve JS expression statement" {
    const std_lib = @import("std");

    const source = "x;";
    var old_ast = Ast.init(std_lib.testing.allocator, source);
    defer old_ast.deinit();

    // identifier_reference "x"
    const id = try old_ast.addNode(.{
        .tag = .identifier_reference,
        .span = .{ .start = 0, .end = 1 },
        .data = .{ .string_ref = .{ .start = 0, .end = 1 } },
    });

    // expression_statement
    const stmt = try old_ast.addNode(.{
        .tag = .expression_statement,
        .span = .{ .start = 0, .end = 2 },
        .data = .{ .unary = .{ .operand = id, .flags = 0 } },
    });

    // program
    const list = try old_ast.addNodeList(&.{stmt});
    _ = try old_ast.addNode(.{
        .tag = .program,
        .span = .{ .start = 0, .end = 2 },
        .data = .{ .list = list },
    });

    var t = try Transformer.init(std_lib.testing.allocator, &old_ast, .{});
    defer t.deinit();

    const root = try t.transform();
    const result = t.ast.getNode(root);

    // program에 statement 1개 보존
    try std_lib.testing.expectEqual(Tag.program, result.tag);
    try std_lib.testing.expectEqual(@as(u32, 1), result.data.list.len);
}

test "Transformer: strip ts_as_expression" {
    const std_lib = @import("std");

    const source = "x as number";
    var old_ast = Ast.init(std_lib.testing.allocator, source);
    defer old_ast.deinit();

    // "x"
    const id = try old_ast.addNode(.{
        .tag = .identifier_reference,
        .span = .{ .start = 0, .end = 1 },
        .data = .{ .string_ref = .{ .start = 0, .end = 1 } },
    });

    // "number" type
    const type_node = try old_ast.addNode(.{
        .tag = .ts_number_keyword,
        .span = .{ .start = 5, .end = 11 },
        .data = .{ .none = 0 },
    });
    _ = type_node; // 타입 노드는 as_expression의 일부이지만 operand가 아님

    // x as number → unary { operand = x }
    const as_expr = try old_ast.addNode(.{
        .tag = .ts_as_expression,
        .span = .{ .start = 0, .end = 11 },
        .data = .{ .unary = .{ .operand = id, .flags = 0 } },
    });

    // expression_statement
    const stmt = try old_ast.addNode(.{
        .tag = .expression_statement,
        .span = .{ .start = 0, .end = 11 },
        .data = .{ .unary = .{ .operand = as_expr, .flags = 0 } },
    });

    // program
    const list = try old_ast.addNodeList(&.{stmt});
    _ = try old_ast.addNode(.{
        .tag = .program,
        .span = .{ .start = 0, .end = 11 },
        .data = .{ .list = list },
    });

    var t = try Transformer.init(std_lib.testing.allocator, &old_ast, .{});
    defer t.deinit();

    const root = try t.transform();

    // program → expression_statement → identifier_reference (as 제거됨)
    const prog = t.ast.getNode(root);
    try std_lib.testing.expectEqual(Tag.program, prog.tag);
    try std_lib.testing.expectEqual(@as(u32, 1), prog.data.list.len);

    // expression_statement의 operand가 직접 identifier_reference를 가리킴
    const stmt_indices = t.ast.extra_data.items[prog.data.list.start .. prog.data.list.start + prog.data.list.len];
    const new_stmt = t.ast.getNode(@enumFromInt(stmt_indices[0]));
    try std_lib.testing.expectEqual(Tag.expression_statement, new_stmt.tag);

    const inner = t.ast.getNode(new_stmt.data.unary.operand);
    try std_lib.testing.expectEqual(Tag.identifier_reference, inner.tag);
}

// ============================================================
// 통합 테스트: 파서 → transformer 연동
// ============================================================

/// 통합 테스트 결과. deinit()으로 모든 리소스를 한 번에 해제.
const TestResult = struct {
    ast: Ast,
    root: NodeIndex,
    scanner: *Scanner,
    parser: *Parser,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TestResult) void {
        self.ast.deinit();
        self.parser.deinit();
        self.allocator.destroy(self.parser);
        self.scanner.deinit();
        self.allocator.destroy(self.scanner);
    }

    /// program의 statement 수를 반환.
    pub fn statementCount(self: *const TestResult) u32 {
        return self.ast.getNode(self.root).data.list.len;
    }
};

/// 테스트 헬퍼: 소스 코드를 파싱 → transformer 실행.
fn parseAndTransform(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    const scanner_ptr = try allocator.create(Scanner);
    scanner_ptr.* = try Scanner.init(allocator, source);

    const parser_ptr = try allocator.create(Parser);
    parser_ptr.* = Parser.init(allocator, scanner_ptr);

    _ = try parser_ptr.parse();

    var t = try Transformer.init(allocator, &parser_ptr.ast, .{});
    const root = try t.transform();
    t.scratch.deinit(allocator);

    return .{ .ast = t.ast, .root = root, .scanner = scanner_ptr, .parser = parser_ptr, .allocator = allocator };
}

test "Integration: type alias stripped" {
    var r = try parseAndTransform(std.testing.allocator, "type Foo = string;");
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 0), r.statementCount());
}

test "Integration: interface stripped" {
    var r = try parseAndTransform(std.testing.allocator, "interface Foo { bar: string; }");
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 0), r.statementCount());
}

test "Integration: JS preserved alongside TS stripped" {
    var r = try parseAndTransform(std.testing.allocator, "const x = 1; type Foo = string;");
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "Integration: enum preserved for codegen" {
    // enum은 런타임 코드 생성 → 삭제되지 않고 codegen으로 전달
    var r = try parseAndTransform(std.testing.allocator, "enum Color { Red, Green, Blue }");
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "Integration: multiple JS statements preserved" {
    var r = try parseAndTransform(std.testing.allocator, "const x = 1; let y = 2; var z = 3;");
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 3), r.statementCount());
}

test "Transformer: isTypeOnlyNode covers all TS type tags" {
    // TS 타입/선언 태그가 isTypeOnlyNode에 포함되는지 검증
    // ts_as_expression 등 값이 있는 expression은 제외
    const std_lib = @import("std");

    // 값을 포함하는 TS expression은 isTypeOnlyNode이 아님
    try std_lib.testing.expect(!Transformer.isTypeOnlyNode(.ts_as_expression));
    try std_lib.testing.expect(!Transformer.isTypeOnlyNode(.ts_satisfies_expression));
    try std_lib.testing.expect(!Transformer.isTypeOnlyNode(.ts_non_null_expression));
    try std_lib.testing.expect(!Transformer.isTypeOnlyNode(.ts_type_assertion));
    try std_lib.testing.expect(!Transformer.isTypeOnlyNode(.ts_instantiation_expression));

    // TS 타입 키워드는 isTypeOnlyNode
    try std_lib.testing.expect(Transformer.isTypeOnlyNode(.ts_any_keyword));
    try std_lib.testing.expect(Transformer.isTypeOnlyNode(.ts_string_keyword));
    try std_lib.testing.expect(Transformer.isTypeOnlyNode(.ts_number_keyword));

    // TS 선언은 isTypeOnlyNode
    try std_lib.testing.expect(Transformer.isTypeOnlyNode(.ts_type_alias_declaration));
    try std_lib.testing.expect(Transformer.isTypeOnlyNode(.ts_interface_declaration));
    // enum은 런타임 코드를 생성하므로 isTypeOnlyNode이 아님
    try std_lib.testing.expect(!Transformer.isTypeOnlyNode(.ts_enum_declaration));
}

/// 테스트 헬퍼: TransformOptions를 지정하여 파싱 → transformer 실행.
pub fn parseAndTransformWithOptions(allocator: std.mem.Allocator, source: []const u8, options: TransformOptions) !TestResult {
    const scanner_ptr = try allocator.create(Scanner);
    scanner_ptr.* = try Scanner.init(allocator, source);

    const parser_ptr = try allocator.create(Parser);
    parser_ptr.* = Parser.init(allocator, scanner_ptr);

    _ = try parser_ptr.parse();

    var t = try Transformer.init(allocator, &parser_ptr.ast, options);
    const root = try t.transform();
    const moved_ast = t.ast;
    t.deinitExceptAst();

    return .{ .ast = moved_ast, .root = root, .scanner = scanner_ptr, .parser = parser_ptr, .allocator = allocator };
}

// ============================================================
// useDefineForClassFields=false 테스트
// ============================================================

test "useDefineForClassFields=false: instance field moved to constructor" {
    // class Foo { foo = 0 } → class Foo { constructor() { this.foo = 0; } }
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { foo = 0 }",
        .{ .use_define_for_class_fields = false },
    );
    defer r.deinit();
    // program에 class_declaration 1개
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "useDefineForClassFields=false: static field moved outside class" {
    // class Foo { static bar = 1; foo = 2 } → class + Foo.bar = 1;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { static bar = 1; foo = 2 }",
        .{ .use_define_for_class_fields = false },
    );
    defer r.deinit();
    // class declaration + static field assignment = 2 statements
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "useDefineForClassFields=false: with existing constructor" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { x = 1; constructor() { console.log('hi'); } }",
        .{ .use_define_for_class_fields = false },
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "useDefineForClassFields=false: with super class" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo extends Bar { x = 1 }",
        .{ .use_define_for_class_fields = false },
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "useDefineForClassFields=false: multiple static fields" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { static a = 1; static b = 2; static c = 3; }",
        .{ .use_define_for_class_fields = false },
    );
    defer r.deinit();
    // class + 3 static assignments
    try std.testing.expectEqual(@as(u32, 4), r.statementCount());
}

test "useDefineForClassFields=false: static without initializer removed" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { static w; }",
        .{ .use_define_for_class_fields = false },
    );
    defer r.deinit();
    // static w; (no init) → 제거, class만 남음
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "useDefineForClassFields=false: instance field without initializer removed" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { y; }",
        .{ .use_define_for_class_fields = false },
    );
    defer r.deinit();
    // y; (no init) → 제거
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "useDefineForClassFields=false: mixed fields and methods" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { x = 1; method() {} static y = 2; }",
        .{ .use_define_for_class_fields = false },
    );
    defer r.deinit();
    // class (with constructor + method) + Foo.y = 2
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "useDefineForClassFields=false: extends with instance and static" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Base { a = 1; } class Child extends Base { b = 2; static c = 3; }",
        .{ .use_define_for_class_fields = false },
    );
    defer r.deinit();
    // Base class + Child class + Child.c = 3
    try std.testing.expectEqual(@as(u32, 3), r.statementCount());
}

test "useDefineForClassFields=true: default behavior preserves fields" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { foo = 0 }",
        .{ .use_define_for_class_fields = true },
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

// ============================================================
// experimentalDecorators 테스트
// ============================================================

test "experimentalDecorators: class decorator" {
    // @sealed class Foo {} → let Foo = class Foo {}; Foo = __decorateClass([sealed], Foo);
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "@sealed class Foo {}",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    // let Foo = class Foo {}; + Foo = __decorateClass([sealed], Foo);
    // → 2 statements (let decl + assignment)
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "experimentalDecorators: method decorator" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { @log greet() {} }",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    // class Foo { greet() {} } + __decorateClass([log], Foo.prototype, "greet", 1);
    // 하지만 method decorator만 있으면 class는 그대로, pending에 decorator call 추가
    // → class_declaration + decorator call = 2 statements
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "experimentalDecorators: preserves class without decorators" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { greet() {} }",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    // decorator 없으면 그대로 1개
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "experimentalDecorators: parameter decorator" {
    // class Foo { method(@track a) {} }
    // → class Foo { method(a) {} } + __decorateClass([__decorateParam(0, track)], Foo.prototype, "method", 1);
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { method(@track a: number) {} }",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    // class_declaration + __decorateClass call = 2 statements
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "experimentalDecorators: parameter decorator + method decorator" {
    // class Foo { @log method(@track a) {} }
    // → class Foo { method(a) {} } + __decorateClass([__decorateParam(0, track), log], Foo.prototype, "method", 1);
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { @log method(@track a: number) {} }",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    // class_declaration + __decorateClass call = 2 statements
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "experimentalDecorators: multiple parameter decorators" {
    // class Foo { method(@a x, @b y) {} }
    // → __decorateClass([__decorateParam(0, a), __decorateParam(1, b)], ...)
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { method(@a x: number, @b y: string) {} }",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "experimentalDecorators: constructor parameter decorator" {
    // class C { constructor(@dec p: number) {} }
    // → let C = class C { constructor(p) {} }; C = __decorateClass([__decorateParam(0, dec)], C);
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class C { constructor(@dec p: number) {} }",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    // let C = class C {...}; + C = __decorateClass(...) = 2 statements
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "experimentalDecorators: constructor param + class decorator" {
    // @sealed class C { constructor(@dec p: number) {} }
    // → let C = class C {...}; C = __decorateClass([__decorateParam(0, dec), sealed], C);
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "@sealed class C { constructor(@dec p: number) {} }",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "experimentalDecorators: decorator call expression @dec(arg)" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { method(@dec(true) p: number) {} }",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "experimentalDecorators: derived class constructor param" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Base {} class C extends Base { constructor(@foo prop: any) { super(); } }",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    // class Base {} + let C = class C extends Base {...} + C = __decorateClass(...) = 3 statements
    try std.testing.expectEqual(@as(u32, 3), r.statementCount());
}

test "experimentalDecorators: static method param decorator" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class C { static method(@dec p: number) {} }",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    // class C {...} + __decorateClass([__decorateParam(0, dec)], C, "method", 1) = 2 statements
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "experimentalDecorators: multiple decorators on single param" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class C { method(@a @b p: number) {} }",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "experimentalDecorators: param with default value" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class C { method(@dec p: number = 42) {} }",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "experimentalDecorators: class + method + param all combined" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "@sealed class C { @log method(@validate p: number) { return p; } }",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    // let C = class C {...} + __decorateClass member + C = __decorateClass class = 3 statements
    try std.testing.expectEqual(@as(u32, 3), r.statementCount());
}

test "experimentalDecorators: inline arrow decorator" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class C { method(@((t: any, k: any, i: any) => {}) p: number) {} }",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "experimentalDecorators: decorator + parameter property modifier" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class C { constructor(@dec public p: number) {} }",
        .{ .experimental_decorators = true },
    );
    defer r.deinit();
    // let C = class C { constructor(p) { this.p = p; } } + C = __decorateClass([__decorateParam(0, dec)], C) = 2
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "experimentalDecorators + es5: inheritance + all decorators" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Base {} @sealed class C extends Base { constructor(@dec p: any) { super(); } @log greet() {} }",
        .{ .experimental_decorators = true, .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    // var Base = IIFE + var C = IIFE (extends+proto inside) + __decorateClass member + C = __decorateClass class = 4 statements
    try std.testing.expectEqual(@as(u32, 4), r.statementCount());
}

// ============================================================
// 두 옵션 동시 활성화 테스트
// ============================================================

test "both options: useDefineForClassFields=false + experimentalDecorators" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { x = 1; @log greet() {} }",
        .{ .use_define_for_class_fields = false, .experimental_decorators = true },
    );
    defer r.deinit();
    // class with constructor (x moved) + __decorateClass call for greet
    // → class_declaration + decorator call = 2 statements
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

// ============================================================
// decorator + ES5 target (#436)
// ============================================================

test "experimentalDecorators + es5: class decorator" {
    // @tag class Foo { greet() {} }
    // → function Foo() {} Foo.prototype.greet = ...; Foo = __decorateClass([tag], Foo);
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "@tag class Foo { greet() { return 'hi'; } }",
        .{ .experimental_decorators = true, .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    // var Foo = IIFE (proto inside) + Foo = __decorateClass(...) = 2 statements
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "experimentalDecorators + es5: method decorator" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { @log greet() {} }",
        .{ .experimental_decorators = true, .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    // var Foo = IIFE (proto inside) + __decorateClass member call = 2 statements
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

test "experimentalDecorators + es5: ctor param decorator" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "class Foo { constructor(@dec p: number) {} }",
        .{ .experimental_decorators = true, .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    // function Foo(p) {} + Foo = __decorateClass([__decorateParam(0, dec)], Foo) = 2 statements
    try std.testing.expectEqual(@as(u32, 2), r.statementCount());
}

// ============================================================
// ES2015 arrow this/arguments 캡처 테스트
// ============================================================

test "ES2015 arrow: this capture inserts var _this = this" {
    // function outer() { const fn = () => this.x; }
    // → function body에 var _this = this; 가 삽입되어야 함
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function outer() { const fn = () => this.x; }",
        .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    // program → 1 statement (function declaration)
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "ES2015 arrow: arguments capture inserts var _arguments = arguments" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function outer() { const fn = () => arguments[0]; }",
        .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "ES2015 arrow: no this → no capture variable" {
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function outer() { const fn = () => 42; }",
        .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "ES2015 arrow: nested arrow shares same _this" {
    // arrow 안의 arrow도 같은 _this를 공유해야 함
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function outer() { const a = () => { const b = () => this.x; }; }",
        .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "ES2015 arrow: inner function resets this scope" {
    // 내부 일반 함수는 자체 this 바인딩 → 별도 _this 스코프
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function outer() { const a = () => { function inner() { const c = () => this.w; } }; }",
        .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

// ============================================================
// Worklet 변환 테스트
// ============================================================

const Codegen = @import("../codegen/codegen.zig").Codegen;
const Plugin = transformer_mod.Plugin;
const worklet_plugin_mod = @import("plugins/worklet_plugin.zig");

/// 테스트 헬퍼: 소스 코드를 파싱 → worklet 변환 → codegen으로 JS 출력.
pub fn transformWorklet(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    return parseAndTransformWithOptions(allocator, source, .{
        .plugins = &plugins,
        .jsx_filename = "test.ts",
    });
}

/// TestResult에서 codegen 출력을 얻는 헬퍼.
/// 반환값은 r.allocator로 할당된 복제본 — r.deinit() 후에도 안전하지만 별도 free 필요.
/// 테스트에서는 allocator가 GPA이므로 검사됨.
pub fn generateCode(r: *TestResult) ![]const u8 {
    var codegen = Codegen.init(r.allocator, &r.ast);
    const code = try codegen.generate(r.root);
    // 코드를 복제 후 codegen 해제 (buf 누수 방지)
    const duped = try r.allocator.dupe(u8, code);
    codegen.deinit();
    return duped;
}

// ================================================================
// Visitor hooks infrastructure tests (Plugin.visitor)
// ================================================================

const plugin_mod = @import("../bundler/plugin.zig");
const VisitorPlugin = plugin_mod.Plugin;
const AstTransformCtx = plugin_mod.AstTransformCtx;
const PluginError = plugin_mod.PluginError;

/// 테스트용 플러그인: object_expression을 string_literal로 교체.
fn testOnObjectExpression(ctx: ?*anyopaque, api: *AstTransformCtx, node_idx: NodeIndex) PluginError!?NodeIndex {
    _ = ctx;
    _ = node_idx;
    const span = try api.addString("\"replaced\"");
    return try api.addNode(.{
        .tag = .string_literal,
        .span = span,
        .data = .{ .string_ref = span },
    });
}

test "Visitor: on_object_expression hook replaces node" {
    // plugin의 on_object_expression 훅이 non-null 반환 시 default 방문 skip + 반환값 사용.
    const test_plugin = VisitorPlugin{
        .name = "test-visitor",
        .visitor = .{ .on_object_expression = testOnObjectExpression },
    };
    const plugins = [_]VisitorPlugin{test_plugin};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "const x = { a: 1 };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // object literal이 "replaced" 문자열로 교체되었는지 확인.
    try std.testing.expect(std.mem.indexOf(u8, code, "\"replaced\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "a:") == null);
}

/// null 반환 훅 — default 방문이 그대로 진행되어야 함.
fn testOnObjectNoOp(ctx: ?*anyopaque, api: *AstTransformCtx, node_idx: NodeIndex) PluginError!?NodeIndex {
    _ = ctx;
    _ = api;
    _ = node_idx;
    return null;
}

test "Visitor: on_object_expression returning null falls through to default" {
    const test_plugin = VisitorPlugin{
        .name = "test-noop",
        .visitor = .{ .on_object_expression = testOnObjectNoOp },
    };
    const plugins = [_]VisitorPlugin{test_plugin};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "const x = { a: 1, b: 2 };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "a: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "b: 2") != null);
}

test "Visitor: no plugins registered — dispatchVisitor short-circuits" {
    // 빈 plugins slice일 때 visitor dispatch가 noop이어야 함.
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "const x = { a: 1 };",
        .{ .plugins = &.{}, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "a: 1") != null);
}

/// 첫 훅은 null, 두 번째 훅이 교체 — first-wins 검증 (둘 다 반환하면 첫 번째가 우승이지만,
/// 첫 번째가 null이면 두 번째 기회).
fn testOnCallReturnTrue(ctx: ?*anyopaque, api: *AstTransformCtx, node_idx: NodeIndex) PluginError!?NodeIndex {
    _ = ctx;
    _ = node_idx;
    const span = try api.addString("true");
    return try api.addNode(.{
        .tag = .boolean_literal,
        .span = span,
        .data = .{ .string_ref = span },
    });
}

test "Visitor: multiple plugins — null-returning plugin lets next plugin handle" {
    const p1 = VisitorPlugin{ .name = "skip", .visitor = .{} }; // no hooks
    const p2 = VisitorPlugin{ .name = "replace", .visitor = .{ .on_call_expression = testOnCallReturnTrue } };
    const plugins = [_]VisitorPlugin{ p1, p2 };
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "const y = foo();",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "const y = true") != null);
}

// ============================================================
// ES5 다운레벨: labeled for-of의 `continue LABEL`/`break LABEL` 보존
// ============================================================
//
// for-of를 iterator protocol(try-catch-finally)로 내리면 원본 for-of 는
// block_statement 로 치환된다. 상위의 `LABEL: for (x of it) {...}` 를 그대로 두면
// label이 iteration statement가 아닌 block을 가리켜
// "SyntaxError: Illegal continue statement" 를 유발한다.
// 수정: labeled_statement가 lowered for-of를 감쌀 때 label을 inner for_statement 에 부여.

fn assertLabelPrecedesFor(code: []const u8, label: []const u8) !void {
    // `LABEL:` 은 반드시 for_statement를 직접 수식해야 한다 (block `{` 앞이면 안 됨).
    // 즉 code 내에서 label 등장 위치가 다음 `try {` 보다 먼저 `for` 가 나와야 한다.
    const label_pos = std.mem.indexOf(u8, code, label) orelse return error.LabelNotFound;
    const for_pos = std.mem.indexOfPos(u8, code, label_pos, "for") orelse return error.ForNotFound;
    if (std.mem.indexOfPos(u8, code, label_pos, "try {")) |try_pos| {
        try std.testing.expect(for_pos < try_pos);
    }
    // label 직후(공백 skip) 다음 토큰이 `for` 여야 한다 — 즉 `LABEL:<ws>for`.
    var i: usize = label_pos + label.len;
    while (i < code.len and (code[i] == ' ' or code[i] == '\n' or code[i] == '\t' or code[i] == '\r')) : (i += 1) {}
    try std.testing.expect(i + 3 <= code.len);
    try std.testing.expectEqualStrings("for", code[i .. i + 3]);
}

test "ES5 downlevel: labeled for-of retains label on inner for_statement" {
    const source =
        \\OUTER: for (const row of data) {
        \\  for (const x of row) {
        \\    if (x === 3) continue OUTER;
        \\  }
        \\}
    ;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .for_of = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try assertLabelPrecedesFor(code, "OUTER:");
    try std.testing.expect(std.mem.indexOf(u8, code, "continue OUTER") != null);
}

test "ES5 downlevel: nested labeled for-of preserves `break OUTER`" {
    const source =
        \\OUTER: for (const row of data) {
        \\  INNER: for (const x of row) {
        \\    if (x === 0) break OUTER;
        \\    if (x < 0) continue INNER;
        \\  }
        \\}
    ;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .for_of = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try assertLabelPrecedesFor(code, "OUTER:");
    try assertLabelPrecedesFor(code, "INNER:");
    try std.testing.expect(std.mem.indexOf(u8, code, "break OUTER") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "continue INNER") != null);
}

test "ES5 downlevel: labeled for-of with assignment-form lvalue" {
    const source =
        \\let x;
        \\LBL: for (x of it) { if (x) break LBL; }
    ;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .for_of = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try assertLabelPrecedesFor(code, "LBL:");
    try std.testing.expect(std.mem.indexOf(u8, code, "break LBL") != null);
}

test "ES5 downlevel: labeled for-of with destructuring binding" {
    const source =
        \\LBL: for (const {a, b} of arr) { if (a) continue LBL; }
    ;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .for_of = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try assertLabelPrecedesFor(code, "LBL:");
    try std.testing.expect(std.mem.indexOf(u8, code, "continue LBL") != null);
}

test "ES5 downlevel: regular labeled `for (;;)` loop unaffected by for-of lowering" {
    const source =
        \\LBL: for (let i = 0; i < n; i++) { if (i === 3) break LBL; }
    ;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .for_of = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try assertLabelPrecedesFor(code, "LBL:");
    try std.testing.expect(std.mem.indexOf(u8, code, "break LBL") != null);
    // for-of lowering의 흔적(Symbol.iterator) 이 나오면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, code, "Symbol.iterator") == null);
}

test "ES5 downlevel: labeled non-for-of statement unchanged" {
    const source =
        \\LOOP: while (cond) { if (x) break LOOP; }
    ;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .for_of = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "LOOP:") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "break LOOP") != null);
}

// ================================================================
// ES2022 top-level await (#1384)
// ================================================================

/// 모듈 모드로 파싱 (top-level await 허용).
fn parseAsModuleAndTransform(allocator: std.mem.Allocator, source: []const u8, options: TransformOptions) !TestResult {
    const scanner_ptr = try allocator.create(Scanner);
    scanner_ptr.* = try Scanner.init(allocator, source);
    scanner_ptr.is_module = true;

    const parser_ptr = try allocator.create(Parser);
    parser_ptr.* = Parser.init(allocator, scanner_ptr);
    parser_ptr.is_module = true;

    _ = try parser_ptr.parse();

    var t = try Transformer.init(allocator, &parser_ptr.ast, options);
    const root = try t.transform();
    const moved_ast = t.ast;
    t.deinitExceptAst();
    return .{ .ast = moved_ast, .root = root, .scanner = scanner_ptr, .parser = parser_ptr, .allocator = allocator };
}

test "TLA: es2022+ no-op (top_level_await supported)" {
    // TLA 가 지원되는 타겟에서는 await 가 그대로 유지된다.
    const source = "await foo();";
    var r = try parseAsModuleAndTransform(
        std.testing.allocator,
        source,
        .{ .unsupported = .{} },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "await foo()") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "async (") == null);
}

test "TLA: wraps top-level await in async IIFE when unsupported" {
    // top_level_await 만 unsupported: `await` → `(async () => { await ... })()`
    const source = "await foo(); console.log(x);";
    var r = try parseAsModuleAndTransform(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .top_level_await = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // 본문 문 두 개가 async arrow IIFE 안으로 이동한다.
    try std.testing.expect(std.mem.indexOf(u8, code, "async") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "await foo()") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "console.log(x)") != null);
    // bare yield 가 leak 되지 않아야 한다.
    try std.testing.expect(std.mem.indexOf(u8, code, "yield") == null);
}

test "TLA: no top-level await → no wrapping" {
    // TLA 가 없으면 wrap 을 적용하지 않는다 (불필요한 IIFE 생성 방지).
    const source = "console.log(1);";
    var r = try parseAsModuleAndTransform(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .top_level_await = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "async") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "console.log(1)") != null);
}

test "TLA: await inside async function is not wrapped" {
    // 함수 안쪽의 await 는 TLA 가 아니므로 wrap 하지 않는다.
    const source = "async function f() { await g(); }";
    var r = try parseAsModuleAndTransform(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .top_level_await = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // top-level IIFE wrapper 를 추가하지 않았어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, code, "(async () =>") == null);
    // async function 자체는 유지.
    try std.testing.expect(std.mem.indexOf(u8, code, "async function") != null);
}

test "TLA: import declarations are kept outside of wrapper" {
    // ESM 규칙상 import 는 module top-level 에만 올 수 있으므로 IIFE 바깥으로 보존.
    const source =
        \\import { x } from "./x.js";
        \\await x();
    ;
    var r = try parseAsModuleAndTransform(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .top_level_await = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    const import_pos = std.mem.indexOf(u8, code, "import") orelse return error.ImportMissing;
    const async_pos = std.mem.indexOf(u8, code, "async") orelse return error.AsyncMissing;
    try std.testing.expect(import_pos < async_pos);
}

test "TLA: ES5 downlevel produces __async + __generator wrap, no bare yield" {
    // target=es5 (async_await + top_level_await + generator 전부 unsupported) 에서
    // bare yield leak 이 없어야 한다 (#1384 재현 케이스).
    const source = "await Promise.resolve(1);";
    var r = try parseAsModuleAndTransform(
        std.testing.allocator,
        source,
        .{ .unsupported = .{
            .top_level_await = true,
            .async_await = true,
            .generator = true,
            .arrow = true,
        } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // __async 경로를 탔으므로 `yield` 자체는 남지 않고 state machine 으로 변환된다.
    try std.testing.expect(std.mem.indexOf(u8, code, "__async") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__generator") != null);
    // bare yield 는 없어야 함.
    try std.testing.expect(std.mem.indexOf(u8, code, "yield ") == null);
}
