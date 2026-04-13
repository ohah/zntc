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
    fn statementCount(self: *const TestResult) u32 {
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

test "Worklet: function with worklet directive adds property assignments" {
    var r = try transformWorklet(std.testing.allocator,
        \\function animate(x) {
        \\  "worklet";
        \\  return withSpring(x + offset);
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // "worklet" 디렉티브가 제거되고, 함수 뒤에 __workletHash, __closure, __initData가 추가됨
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__initData") != null);
    // "worklet" 디렉티브는 출력에서 제거됨
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\"") == null);
}

test "Worklet: function without worklet directive is unchanged" {
    var r = try transformWorklet(std.testing.allocator,
        \\function foo(x) {
        \\  return x + 1;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // worklet 변환 없음
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure") == null);
}

test "Worklet: statement count includes property assignments" {
    // function + 3 property assignments = 4 statements
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function animate(x) { \"worklet\"; return withSpring(x + offset); }",
        .{ .plugins = &[_]Plugin{worklet_plugin_mod.plugin()}, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    // 1 function declaration + 4 property assignments (hash/closure/initData/stackDetails/pluginVersion) = 6 statements
    try std.testing.expectEqual(@as(u32, 6), r.statementCount());
}

test "Worklet: no closure vars produces empty closure object" {
    var r = try transformWorklet(std.testing.allocator,
        \\function simple() {
        \\  "worklet";
        \\  return 42;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: multiple closure vars are sorted alphabetically" {
    var r = try transformWorklet(std.testing.allocator,
        \\function anim(x) {
        \\  "worklet";
        \\  return withSpring(x + offset + scale);
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // closure 변수: offset, scale, withSpring (알파벳 순)
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "offset") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "scale") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "withSpring") != null);
}

test "Worklet: parameters are not closure vars" {
    var r = try transformWorklet(std.testing.allocator,
        \\function anim(x, y) {
        \\  "worklet";
        \\  return x + y + offset;
        \\}
    );
    defer r.deinit();
    // function + 5 property assignments = 6 statements
    try std.testing.expectEqual(@as(u32, 6), r.statementCount());
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // x, y는 파라미터이므로 closure에 포함되지 않아야 함
    // __closure에 offset만 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { offset: offset }") != null);
}

test "Worklet: initData contains code and location" {
    var r = try transformWorklet(std.testing.allocator,
        \\function move() {
        \\  "worklet";
        \\  return velocity;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // __initData에 code와 location 필드가 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "code:") != null or
        std.mem.indexOf(u8, code, "code: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "location:") != null or
        std.mem.indexOf(u8, code, "location: ") != null);
    // location에 test.ts 경로가 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "test.ts") != null);
}

test "Worklet: non-worklet function mixed with worklet function" {
    var r = try transformWorklet(std.testing.allocator,
        \\function normal() { return 1; }
        \\function anim() {
        \\  "worklet";
        \\  return 2;
        \\}
    );
    defer r.deinit();
    // normal(1) + anim(1) + 5 property assignments = 7 statements
    try std.testing.expectEqual(@as(u32, 7), r.statementCount());
}

test "Worklet: globals are excluded from closure vars" {
    var r = try transformWorklet(std.testing.allocator,
        \\function anim() {
        \\  "worklet";
        \\  console.log(Math.random());
        \\  return undefined;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // console, Math, undefined는 글로벌이므로 closure에 포함되지 않아야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: worklet transform disabled when no plugins" {
    // plugins 없이 변환하면 worklet 처리 안 됨
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function f() { \"worklet\"; return 1; }",
        .{},
    );
    defer r.deinit();
    // plugins가 없으므로 worklet 변환 없음 — statement 1개 (함수만)
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "Worklet: rest params are not included in closure (#1104)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function guard(fn, ...args) { \"worklet\"; return fn(...args); }",
        .{
            .plugins = &plugins,
            .jsx_filename = "test.ts",
            .unsupported = TransformOptions.compat.fromESTarget(.es5),
        },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // pre-visit body 사용: fn, args는 파라미터이므로 closure 비어야 함.
    // ES5 헬퍼(__toConsumableArray)는 pre-visit body에 없으므로 closure에 미포함.
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: directive found after rest params transform (#1102)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function guard(fn, ...args) { \"worklet\"; return fn(...args); }",
        .{
            .plugins = &plugins,
            .jsx_filename = "test.ts",
            .unsupported = TransformOptions.compat.fromESTarget(.es5),
        },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // worklet 변환이 적용되어야 함 (디렉티브가 rest params 뒤로 밀려도)
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    // "worklet" 디렉티브가 제거되어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\"") == null);
}

test "Worklet: function_expression worklet produces IIFE factory (#1100)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var x = wrap(function myWorklet() { \"worklet\"; return 42; });",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // IIFE factory로 감싸져야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    // 원본 함수가 IIFE 안에서 var로 할당
    try std.testing.expect(std.mem.indexOf(u8, code, "var myWorklet") != null);
    // return으로 반환
    try std.testing.expect(std.mem.indexOf(u8, code, "return myWorklet") != null);
}

test "Worklet: property access not collected as closure var (if_statement ternary)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(std.testing.allocator,
        \\function calc(current, previous) {
        \\  "worklet";
        \\  if (previous === undefined) {
        \\    return current.force;
        \\  } else {
        \\    return current.force - previous.force;
        \\  }
        \\}
    , .{ .plugins = &plugins, .jsx_filename = "test.ts" });
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // 'force'는 property access이므로 closure에 포함되면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: nested member expression a.b.c excludes property names" {
    var r = try transformWorklet(std.testing.allocator,
        \\function f(obj) {
        \\  "worklet";
        \\  return obj.a.b.c;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // obj는 param → closure 비어야 함. a, b, c는 property → 제외
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: external variable captured, property excluded" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var config = { speed: 1 }; function f(x) { \"worklet\"; return x * config.speed; }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // config → closure, speed → property 제외
    try std.testing.expect(std.mem.indexOf(u8, code, "config") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { config: config }") != null);
}

test "Worklet: try-catch body member access excludes property" {
    var r = try transformWorklet(std.testing.allocator,
        \\function f(obj) {
        \\  "worklet";
        \\  try { return obj.data; } catch(e) { return e.message; }
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // obj, e는 param/catch local → closure 비어야 함. data, message는 property → 제외
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: destructuring locals not in closure" {
    var r = try transformWorklet(std.testing.allocator,
        \\function f(obj) {
        \\  "worklet";
        \\  const { x, y } = obj;
        \\  return x + y;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // x, y는 destructuring → locals. obj는 param → locals.
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: conditional expression member access" {
    var r = try transformWorklet(std.testing.allocator,
        \\function f(x, flag) {
        \\  "worklet";
        \\  return flag ? x.a : x.b;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // a, b는 property → 제외
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: inner function declaration is local" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var cb = 1; function f() { \"worklet\"; function inner() { return 1; } return cb; }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // inner → local function. cb → external closure var.
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { cb: cb }") != null);
}

test "Worklet: globalThis property not collected as closure var (unary_expression extra)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var fn = 1; function setup() { \"worklet\"; if (!globalThis.__myProp) { globalThis.__myProp = fn; } }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // __myProp는 globalThis의 property이므로 closure에 포함되면 안 됨
    // fn만 closure에 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { fn: fn }") != null);
}

test "Worklet: arrow function params not in closure (ES5 lowering)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var ext = 1; export const pf = (value, context) => { \"worklet\"; return ext + value + context; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // value, context는 파라미터이므로 closure에 포함되면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
}

test "Worklet: arrow function with typed var params not in closure (ES5 lowering)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "type Fn = any; var ext = 1; export const pf: Fn = (value, context) => { \"worklet\"; return ext + value + context; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // type annotation이 변수에 있고 params에는 없는 경우에도 params는 제외되어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
}

test "Worklet: pre-visit body used for initData (no ES5 helpers in closure)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "export function setup() { \"worklet\"; const f = (cb: any, ...args: any[]) => { cb(...args); }; globalThis.setTimeout = f as any; }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // pre-visit body 사용: ES5 헬퍼(__toConsumableArray)가 closure에 없어야 함.
    // Hermes UI runtime이 spread를 네이티브 지원하므로 ES5 변환 불필요.
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: nested function captures outer refs but params stay local" {
    var r = try transformWorklet(std.testing.allocator,
        \\var ext = 1;
        \\export function w() {
        \\  "worklet";
        \\  function inner(x) { return x + ext; }
        \\  return inner(1);
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // ext는 inner body에서 참조하는 외부 변수 → worklet closure에 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "ext:ext}=this.__closure") != null);
    // inner의 param x는 closure에 포함되면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, code, "x:x") == null);
}

test "Worklet: default param (c = 0) not in closure" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "export const f = (c = 0) => { \"worklet\"; return c * 2; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // c는 default parameter — closure에 포함되면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: default param with external ref" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var scale = 2; export const f = (c = 0) => { \"worklet\"; return c * scale; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // c는 param → 제외, scale은 외부 참조 → 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { scale: scale }") != null);
}

test "Worklet: __stackDetails property is emitted" {
    // Babel workletFactory.ts:298-327 포맷: [new global.Error(), lineOffset, -27]
    var r = try transformWorklet(std.testing.allocator,
        \\function f() {
        \\  "worklet";
        \\  return 1;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__stackDetails = [new global.Error()") != null);
}

test "Worklet: initData code has no ES5 helpers (spread preserved)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "export function g(fn, ...args) { \"worklet\"; return fn(...args); }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // initData.code에 __toConsumableArray가 없어야 함 (pre-visit body 사용)
    const init_start = std.mem.indexOf(u8, code, "__initData = { code:") orelse unreachable;
    const init_end = std.mem.indexOfPos(u8, code, init_start, "location:") orelse unreachable;
    const init_section = code[init_start..init_end];
    try std.testing.expect(std.mem.indexOf(u8, init_section, "__toConsumableArray") == null);
    // 원본 spread 문법이 유지되어야 함
    try std.testing.expect(std.mem.indexOf(u8, init_section, "...args") != null);
}

test "Worklet: initData code has no TS syntax (as expression stripped)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "export function g(v: number) { \"worklet\"; return v as any; }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // initData.code에 TS 'as' 구문이 없어야 함
    const init_start = std.mem.indexOf(u8, code, "__initData = { code:") orelse unreachable;
    const init_end = std.mem.indexOfPos(u8, code, init_start, "location:") orelse unreachable;
    const init_section = code[init_start..init_end];
    try std.testing.expect(std.mem.indexOf(u8, init_section, " as ") == null);
}

test "Worklet: global and __DEV__ not captured in closure" {
    var r = try transformWorklet(std.testing.allocator,
        \\export function f() {
        \\  "worklet";
        \\  if (__DEV__) { console.log(global); }
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // global과 __DEV__는 JS_GLOBALS에 등록 → closure에 포함 안 됨
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: multiple default params not in closure" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var ext = 1; export const f = (a = 0, b = 1) => { \"worklet\"; return a + b + ext; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // a, b는 default params → 제외, ext만 closure에
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
}

test "Worklet: arrow function with worklet directive is transformed (ES5)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var ext = 1; export const f = () => { \"worklet\"; return ext; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // arrow worklet이 IIFE factory로 변환되어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
    // "worklet" 디렉티브가 제거되어야 함 (__initData 안은 제외)
    try std.testing.expect(std.mem.indexOf(u8, code, "__initData") != null);
}

test "Worklet: nested worklet calls another worklet" {
    var r = try transformWorklet(std.testing.allocator,
        \\function helper() {
        \\  "worklet";
        \\  return 42;
        \\}
        \\function main() {
        \\  "worklet";
        \\  return helper();
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // 둘 다 worklet으로 변환
    var count: usize = 0;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, code, search, "__workletHash")) |pos| {
        count += 1;
        search = pos + 1;
    }
    try std.testing.expect(count >= 2);
    // main의 closure에 helper가 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "helper: helper") != null);
}

test "Worklet: computed property access in worklet body" {
    var r = try transformWorklet(std.testing.allocator,
        \\var obj = {};
        \\var key = "x";
        \\function f() {
        \\  "worklet";
        \\  return obj[key];
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // obj와 key 모두 closure에 포함 (computed access는 둘 다 외부 참조)
    try std.testing.expect(std.mem.indexOf(u8, code, "key: key") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "obj: obj") != null);
}

test "Worklet: object method with worklet directive is transformed" {
    var r = try transformWorklet(std.testing.allocator,
        \\var logger = { warn(msg) {
        \\  "worklet";
        \\  return msg;
        \\} };
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // object method worklet → object_property + IIFE로 변환
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__initData") != null);
    // method가 object_property value로 변환됨
    try std.testing.expect(std.mem.indexOf(u8, code, "warn:") != null);
}

test "Worklet: object method with outer closure vars captured" {
    var r = try transformWorklet(std.testing.allocator,
        \\var config = {};
        \\var obj = { build(props) {
        \\  "worklet";
        \\  return config[props];
        \\} };
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "config:config}=this.__closure") != null);
}

test "Worklet: getter with worklet directive becomes factory body (Babel 호환)" {
    // getter/setter는 class body에서 IIFE 교체 불가 → body를 factory block으로 치환.
    // `get x() { var x = function(){...}; x.__workletHash=...; return x; }`
    // getter 접근 시 worklet 함수를 반환 (Reanimated 런타임과 일치).
    var r = try transformWorklet(std.testing.allocator,
        \\var obj = { get x() {
        \\  "worklet";
        \\  return 1;
        \\} };
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
}

test "Worklet: scope hoisting rename reflected in closure value" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        \\import { helper } from "./a";
        \\import { helper as h2 } from "./b";
        \\export function w() { "worklet"; return helper() + h2(); }
    ,
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // closure에 helper가 포함되어야 함 (explicit key-value)
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "helper:") != null);
}

test "Worklet: auto-workletization for scheduleOnUI argument" {
    var r = try transformWorklet(std.testing.allocator,
        \\function scheduleOnUI(fn) {}
        \\scheduleOnUI(() => {
        \\  console.log("auto worklet");
        \\});
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // auto-worklet 변환: __workletHash가 주입되어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__initData") != null);
}

test "Worklet: auto-workletization for runOnUI argument" {
    var r = try transformWorklet(std.testing.allocator,
        \\function runOnUI(fn) { return fn; }
        \\runOnUI(() => {
        \\  return 42;
        \\})();
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "Worklet: auto-workletization skips non-function args" {
    var r = try transformWorklet(std.testing.allocator,
        \\function scheduleOnUI(fn) {}
        \\var x = 1;
        \\scheduleOnUI(x);
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // 인자가 함수가 아니면 worklet 변환 없음
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "Worklet: auto-workletization with correct arg index (withDecay arg 1)" {
    var r = try transformWorklet(std.testing.allocator,
        \\function withDecay(config, callback) {}
        \\withDecay({}, () => {
        \\  console.log("done");
        \\});
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // withDecay의 두 번째 인자(index 1)가 worklet화
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "Worklet: auto-workletization does not affect wrong arg index" {
    var r = try transformWorklet(std.testing.allocator,
        \\function withDecay(config, callback) {}
        \\withDecay(() => { return 1; }, null);
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // withDecay의 첫 번째 인자(index 0)는 auto-worklet 대상 아님
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "Worklet: method auto-workletization for gesture handler onBegin" {
    // Babel parity: `Gesture.Foo()` 체인의 onBegin만 workletize.
    var r = try transformWorklet(std.testing.allocator,
        \\Gesture.Pan().onBegin((e) => {
        \\  console.log(e);
        \\});
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "Worklet: method onBegin on non-gesture-object receiver is NOT workletized" {
    // 임의 객체의 `.onBegin()`은 auto-worklet 대상 아님 (Babel parity).
    var r = try transformWorklet(std.testing.allocator,
        \\var gesture = {};
        \\gesture.onBegin((e) => {
        \\  console.log(e);
        \\});
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "Worklet: auto-workletization inside worklet function body" {
    var r = try transformWorklet(std.testing.allocator,
        \\function scheduleOnUI(fn) {}
        \\function outer() {
        \\  "worklet";
        \\  scheduleOnUI(() => {
        \\    console.log("inner");
        \\  });
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // outer 함수의 __workletHash
    try std.testing.expect(std.mem.indexOf(u8, code, "outer.__workletHash") != null);
    // inner arrow도 auto-worklet 변환되어야 함 (IIFE로 wrapping)
    // 이전 버그: stripDirective가 원본 body로 덮어써서 inner 변환이 손실
    const count = std.mem.count(u8, code, "__workletHash");
    try std.testing.expect(count >= 2); // outer + inner
}

test "Worklet: closure analysis includes refs inside object getters/setters/methods" {
    var r = try transformWorklet(std.testing.allocator,
        \\function outerFn() { return 42; }
        \\function w() {
        \\  "worklet";
        \\  return { get v() { return outerFn(); }, set v(x) { outerFn(); }, m() { outerFn(); } };
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // outerFn이 __closure에 포함되어야 함 (getter/setter/method body에서 참조)
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "outerFn") != null);
    // __initData.code에서 this.__closure로 destructure
    try std.testing.expect(std.mem.indexOf(u8, code, "outerFn:outerFn}=this.__closure") != null);
}

test "Worklet: object method worklet strips directive from IIFE body" {
    // method_definition 경로에서 stripped body를 사용하지 않으면
    // IIFE 내부 function 바디에 `'worklet'` directive가 잔존 (Reanimated runtime 크래시).
    var r = try transformWorklet(std.testing.allocator,
        \\var ERROR_MESSAGES = {
        \\  invalidColor(color) {
        \\    "worklet";
        \\    return "Invalid color: " + color;
        \\  }
        \\};
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "invalidColor.__workletHash") != null);
}

test "Worklet: recursive function self-reference excluded from __closure" {
    var r = try transformWorklet(std.testing.allocator,
        \\function recurse(n) {
        \\  "worklet";
        \\  if (n > 0) recurse(n - 1);
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: TS type assertion (as) does not break closure analysis" {
    var r = try transformWorklet(std.testing.allocator,
        \\var outer = {} as any;
        \\function w() {
        \\  "worklet";
        \\  return (outer as any).value;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "outer:outer}=this.__closure") != null);
}

test "Worklet: closure captures through ternary, template literal, array, spread" {
    var r = try transformWorklet(std.testing.allocator,
        \\var a = 1, b = 2, c = 3, d = [4];
        \\function w() {
        \\  "worklet";
        \\  var x = a ? b : c;
        \\  var y = `${a}`;
        \\  var z = [...d, a];
        \\  return x + y + z;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "a:a") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "b:b") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "c:c") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "d:d") != null);
}

test "Worklet: closure captures through switch, for-in, try-catch" {
    var r = try transformWorklet(std.testing.allocator,
        \\var val = 1, obj = {}, fn2 = () => {};
        \\function w() {
        \\  "worklet";
        \\  switch (val) { case 1: break; }
        \\  for (var k in obj) {}
        \\  try { fn2(); } catch (e) {}
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "val:val") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "obj:obj") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "fn2:fn2") != null);
    // catch param 'e'는 closure가 아닌 로컬
    try std.testing.expect(std.mem.indexOf(u8, code, "e:e") == null);
}

test "Worklet: method param shadowing does not leak to outer closure" {
    var r = try transformWorklet(std.testing.allocator,
        \\var x = 1;
        \\function w() {
        \\  "worklet";
        \\  var x = 2;
        \\  return { set v(x) { console.log(x); } };
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // x는 worklet 내부 로컬이므로 closure에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: nested object with computed property and new expression" {
    var r = try transformWorklet(std.testing.allocator,
        \\var key = "a", Cls = class {};
        \\function w() {
        \\  "worklet";
        \\  var o = { [key]: new Cls() };
        \\  return o;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "key:key") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "Cls:Cls") != null);
}

test "Worklet: nested function and arrow capture outer imports" {
    var r = try transformWorklet(std.testing.allocator,
        \\var isShared = (v) => v != null;
        \\var helper = () => 42;
        \\function w() {
        \\  "worklet";
        \\  function extract(x) {
        \\    if (isShared(x)) return;
        \\    var fn = () => helper();
        \\  }
        \\  return extract;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // 중첩 function 안의 isShared와 arrow 안의 helper 모두 worklet closure에 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "isShared:isShared") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "helper:helper") != null);
    // extract의 param x는 closure에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, " x:x") == null);
}

test "Worklet: arrow callback param does not leak into outer closure (cover grammar)" {
    var r = try transformWorklet(std.testing.allocator,
        \\function w() {
        \\  "worklet";
        \\  var arr = [];
        \\  arr.forEach((item) => item());
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // arrow param 'item'은 closure에 없어야 함 (cover grammar 파라미터)
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: arrow with destructured param does not leak" {
    var r = try transformWorklet(std.testing.allocator,
        \\function w() {
        \\  "worklet";
        \\  var fn = ({ a, b }) => a + b;
        \\  return fn;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
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
