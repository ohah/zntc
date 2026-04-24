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
/// `ast` 는 transformer 에서 소유권 이전받은 heap-allocated `*Ast`.
const TestResult = struct {
    ast: *Ast,
    root: NodeIndex,
    scanner: *Scanner,
    parser: *Parser,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TestResult) void {
        self.ast.deinit();
        self.allocator.destroy(self.ast);
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
    errdefer allocator.destroy(scanner_ptr);
    scanner_ptr.* = try Scanner.init(allocator, source);
    errdefer scanner_ptr.deinit();

    const parser_ptr = try allocator.create(Parser);
    errdefer allocator.destroy(parser_ptr);
    parser_ptr.* = Parser.init(allocator, scanner_ptr);
    errdefer parser_ptr.deinit();

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
    errdefer allocator.destroy(scanner_ptr);
    scanner_ptr.* = try Scanner.init(allocator, source);
    errdefer scanner_ptr.deinit();

    const parser_ptr = try allocator.create(Parser);
    errdefer allocator.destroy(parser_ptr);
    parser_ptr.* = Parser.init(allocator, scanner_ptr);
    errdefer parser_ptr.deinit();

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
    var codegen = Codegen.init(r.allocator, r.ast);
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
// #1797 for-of + let closure capture — ES5 down-level 시 per-iteration fresh
// binding semantics 유지 (body 를 `var _loopN = function(key){...}` 로 추출).
// 회귀 시 `for (let k of ...) arr.push(() => k)` 가 모든 클로저에서 마지막
// k 를 공유 → bungae 의 `@radix-ui/react-slot __copyProps` 가 getter 로
// 마지막 key 만 반환해 `React.forwardRef is not a function (it is '19.2.0')`.
// ================================================================

test "#1797 for-of + let + arrow closure: body 를 _loop 함수로 추출" {
    const source =
        \\for (let key of keys) {
        \\  arr.push(() => from[key]);
        \\}
    ;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .for_of = true, .block_scoping = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // body 가 _loop 함수로 추출되고 루프 내부는 _loop(key) 호출만 남음.
    try std.testing.expect(std.mem.indexOf(u8, code, "_loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "function(key)") != null or
        std.mem.indexOf(u8, code, "function (key)") != null);
    // 루프 내부에 arr.push 가 직접 emit 되면 회귀 — _loop 안으로 들어가야.
    const push_pos = std.mem.indexOf(u8, code, "arr.push") orelse unreachable;
    const loop_pos = std.mem.indexOf(u8, code, "_loop") orelse unreachable;
    try std.testing.expect(push_pos > loop_pos);
}

test "#1797 for-of + let + function expression closure: 동일 변환" {
    const source =
        \\for (let k of arr) {
        \\  cbs.push(function() { return k; });
        \\}
    ;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .for_of = true, .block_scoping = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "_loop") != null);
    // 파라미터로 k 가 전달
    try std.testing.expect(std.mem.indexOf(u8, code, "(k)") != null);
}

test "#1797 for-of + const + closure: const 도 lexical 이므로 동일 변환" {
    const source =
        \\for (const k of arr) {
        \\  cbs.push(() => k);
        \\}
    ;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .for_of = true, .block_scoping = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "_loop") != null);
}

test "#1797 for-of + let destructuring + closure: 여러 binding 모두 params" {
    const source =
        \\for (let { a, b } of arr) {
        \\  cbs.push(() => a + b);
        \\}
    ;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .for_of = true, .block_scoping = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "_loop") != null);
    // 두 binding (a, b) 모두 _loop 파라미터로.
    try std.testing.expect(std.mem.indexOf(u8, code, "a, b") != null or
        std.mem.indexOf(u8, code, "a,b") != null);
}

test "#1797 for-of + let + closure + break: 제어흐름 처리" {
    const source =
        \\for (let k of arr) {
        \\  if (k === 'stop') break;
        \\  cbs.push(() => k);
        \\}
    ;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .for_of = true, .block_scoping = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "_loop") != null);
    // buildLoopClosureWithFlow 가 break 를 return sentinel 로 변환.
    try std.testing.expect(std.mem.indexOf(u8, code, "return") != null);
}

test "#1797 negative: for-of + let 인데 closure 없으면 _loop 변환 안 함" {
    // body 내부가 직접 값 사용 — closure capture 없음 → 기존 경로 유지.
    const source =
        \\for (let k of arr) {
        \\  total = total + k;
        \\}
    ;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .for_of = true, .block_scoping = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "_loop") == null);
    // body 는 여전히 var k = _e.value; total = total + k; 형태.
    try std.testing.expect(std.mem.indexOf(u8, code, "var k") != null);
}

test "#1797 negative: for-of + var (non-lexical) + closure → 변환 안 함" {
    // var 는 function scope 이므로 원래 per-iteration fresh binding 이 없다.
    // 개발자가 var 를 쓴 의도 존중 — _loop 변환 비활성.
    const source =
        \\for (var k of arr) {
        \\  cbs.push(() => k);
        \\}
    ;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .for_of = true, .block_scoping = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "_loop") == null);
}

test "#1797 negative: for-of down-level 꺼져있으면 변환 자체 비활성" {
    // for_of=false 이면 ES2015 native for-of 유지 — closure capture 변환 불필요.
    const source =
        \\for (let k of arr) cbs.push(() => k);
    ;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .for_of = false, .block_scoping = false } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "_loop") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "for (let k of") != null);
}

test "#1797 bungae __copyProps pattern: getter 가 iteration-local key 캡처" {
    // @radix-ui/react-slot 이 esbuild 로 빌드한 `__copyProps` 의 정확한 패턴.
    // RN Hermes 에서 `React$250 = '19.2.0'` crash 를 재현한 입력.
    const source =
        \\for (let key of __getOwnPropNames(from)) {
        \\  if (!__hasOwnProp.call(to, key) && key !== except)
        \\    __defProp(to, key, {
        \\      get: () => from[key],
        \\      enumerable: true,
        \\    });
        \\}
    ;
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        source,
        .{ .unsupported = .{ .for_of = true, .block_scoping = true } },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "_loop") != null);
    // 루프 body 에서 직접 __defProp 가 호출되면 회귀 (closure 공유) — _loop 함수 내부로.
    const defprop_pos = std.mem.indexOf(u8, code, "__defProp") orelse unreachable;
    const loop_pos = std.mem.indexOf(u8, code, "_loop") orelse unreachable;
    try std.testing.expect(defprop_pos > loop_pos);
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

// ============================================================
// verbatimModuleSyntax 테스트 (TS 5.0+)
// ============================================================
//
// 주의: elision 은 semantic analyzer 가 populated symbols 를 만든 뒤에만 발동한다.
// 단위 헬퍼(parseAsModuleAndTransform)는 semantic 을 건너뛰므로 여기서는 transpile 모듈을
// 경유해 end-to-end 로 검증한다.

const transpile_mod = @import("../transpile.zig");

test "verbatimModuleSyntax=false (default): unused value import is elided" {
    var result = try transpile_mod.transpile(
        std.testing.allocator,
        \\import { foo } from "./bar";
    ,
        "input.ts",
        .{},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "import") == null);
}

test "verbatimModuleSyntax=true: unused value import is preserved" {
    var result = try transpile_mod.transpile(
        std.testing.allocator,
        \\import { foo } from "./bar";
    ,
        "input.ts",
        .{ .verbatim_module_syntax = true },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "import") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "\"./bar\"") != null);
}

test "verbatimModuleSyntax=true: type-only named specifier 는 여전히 제거" {
    var result = try transpile_mod.transpile(
        std.testing.allocator,
        \\import { type T, foo } from "./bar";
        \\const x = foo;
    ,
        "input.ts",
        .{ .verbatim_module_syntax = true },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "type T") == null);
}

test "verbatimModuleSyntax=true: `import type` 전체 선언은 여전히 drop" {
    // `import type` 은 parse 단계에서 NodeIndex.none 으로 elide 되므로 flag 와 무관.
    var result = try transpile_mod.transpile(
        std.testing.allocator,
        \\import type { T } from "./bar";
    ,
        "input.ts",
        .{ .verbatim_module_syntax = true },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "import") == null);
}

test "side-effect import 는 verbatim 과 무관하게 항상 보존" {
    // `import "./bar"` 은 binding 이 없어 elision 대상이 아님.
    var result = try transpile_mod.transpile(
        std.testing.allocator,
        \\import "./bar";
    ,
        "input.ts",
        .{},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "\"./bar\"") != null);
}

test "verbatimModuleSyntax=true: 미사용 default import 보존" {
    var result = try transpile_mod.transpile(
        std.testing.allocator,
        \\import foo from "./bar";
    ,
        "input.ts",
        .{ .verbatim_module_syntax = true },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "import") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "foo") != null);
}

// ============================================================
// type-only import binding elision (#1791)
//
// analyzer 가 TS type node 에 진입할 때 `type_context_depth` 를 올려 내부 식별자의
// Reference 에 `flags.type_context=true` 를 기록한다. Phase D 는 이 flag 를 근거로
// **named specifier** 에 한정해 "value 참조 0" 인 binding 을 drop.
//
// 회귀 방지 설계 (#1793 revert 원인):
// - default/namespace import 는 JSX pragma / CSS-in-JS default export / namespace
//   member access 같은 implicit value use 가 많아 elision 대상에서 제외
// - `export { X }` re-export 의 local 은 analyzer 가 value 참조로 등록 (이전에는
//   검증만 하고 Reference 를 만들지 않아 Phase D 가 오판)
// - `typeof X` / `keyof X` 는 `value_as_type` bit 로 구분 — type 전용 사용 간주
// ============================================================

test "#1791 type-only elision: positive + negative cases" {
    const Case = struct {
        name: []const u8,
        src: []const u8,
        path: []const u8 = "input.ts",
        verbatim: bool = false,
        must_contain: []const []const u8 = &.{},
        must_not_contain: []const []const u8 = &.{},
    };
    const cases = [_]Case{
        // ---------- POSITIVE: elide 되어야 할 것 ----------
        .{
            .name = "named mixed: type-only specifier 만 drop",
            .src =
            \\import { A, B } from "./lib";
            \\export function f(x: A): void {}
            \\export const v = B();
            ,
            .must_contain = &.{"import { B } from \"./lib\""},
            .must_not_contain = &.{ " A,", ", A ", "{ A," },
        },
        .{
            .name = "named all type-only → declaration 전체 drop",
            .src =
            \\import { A, B } from "./lib";
            \\export function f(x: A): B { return undefined; }
            ,
            .must_not_contain = &.{ "import", "./lib" },
        },
        .{
            .name = "named alias: local 이 type-only 면 해당 specifier 만 drop",
            .src =
            \\import { X as Y, Z } from "./lib";
            \\export function f(x: Y): void {}
            \\export const v = Z();
            ,
            .must_contain = &.{"import { Z } from \"./lib\""},
            .must_not_contain = &.{ "X as Y", " Y,", "{ Y," },
        },
        .{
            .name = "nested generic: Array<Map<string, A>> 안의 A 는 type-only",
            .src =
            \\import { A, Util } from "./lib";
            \\export type T = Array<Map<string, A>>;
            \\export const v = Util();
            ,
            .must_contain = &.{"import { Util } from \"./lib\""},
            .must_not_contain = &.{"{ A,"},
        },
        .{
            .name = "typeof X: value_as_type 로 분류되어 drop",
            .src =
            \\import { X, Used } from "./lib";
            \\export type T = typeof X;
            \\export const v = Used();
            ,
            .must_contain = &.{"import { Used } from \"./lib\""},
            .must_not_contain = &.{"{ X,"},
        },

        // ---------- NEGATIVE: keep 되어야 할 것 (false positive 방지) ----------
        .{
            // #1793 revert 의 직접 원인 — `export { React }` 의 React 가 value 참조.
            // analyzer 가 이 local 을 resolveIdentifier 로 등록하므로 Phase D 가 유지.
            .name = "export re-export: named specifier 는 유지",
            .src =
            \\import { A, B } from "./lib";
            \\export { A, B };
            ,
            .must_contain = &.{"import { A, B } from \"./lib\""},
        },
        .{
            // default 는 JSX pragma / CSS-in-JS default 등 implicit value use 가 많아
            // Phase D elision 대상에서 제외 — 설령 type 위치에서만 보여도 유지.
            .name = "default binding: type-only 사용 이어도 유지",
            .src =
            \\import Foo from "./lib";
            \\export function f(x: Foo): void {}
            ,
            .must_contain = &.{"import Foo from \"./lib\""},
        },
        .{
            .name = "namespace binding: type-only 사용 이어도 유지",
            .src =
            \\import * as NS from "./lib";
            \\export function f(x: NS.Foo): void {}
            ,
            .must_contain = &.{"import * as NS from \"./lib\""},
        },
        .{
            .name = "namespace member access: value 참조로 유지",
            .src =
            \\import * as React from "react";
            \\export const C = React.forwardRef((a: any, r: any) => null);
            ,
            .must_contain = &.{"import * as React from \"react\""},
        },
        .{
            .name = "class extends: base 는 value 참조로 유지",
            .src =
            \\import { Base } from "./lib";
            \\export class Derived extends Base {}
            ,
            .must_contain = &.{"import { Base } from \"./lib\""},
        },
        .{
            // 함수 호출의 인자 — 가장 일반적인 value 참조.
            .name = "function argument: value 참조로 유지",
            .src =
            \\import { handler, Token } from "./di";
            \\export const result = handler(Token);
            ,
            .must_contain = &.{"import { handler, Token } from \"./di\""},
        },
        .{
            // 조건식 / 연산 — value 참조.
            .name = "conditional expression: value 참조로 유지",
            .src =
            \\import { flag, fallback } from "./lib";
            \\export const v = flag ? 1 : fallback();
            ,
            .must_contain = &.{"import { flag, fallback } from \"./lib\""},
        },
        .{
            // `import type { X }` 전체 type-only 는 parse 단계에서 drop.
            .name = "import type 전체 선언은 parse 단계에서 drop",
            .src =
            \\import type { A } from "./lib";
            \\export const x = 1;
            ,
            .must_not_contain = &.{ "import", "./lib" },
        },
        .{
            // `import { type X, Y }` inline type modifier — X 만 drop.
            .name = "inline type modifier: 해당 specifier 만 drop",
            .src =
            \\import { type A, B } from "./lib";
            \\export function f(x: A): void { B(); }
            ,
            .must_contain = &.{"import { B } from \"./lib\""},
            .must_not_contain = &.{ "type A", "{ A,", ", A }" },
        },

        // ---------- VERBATIM: 명시적 보존 ----------
        .{
            .name = "verbatim=true: named type-only 도 보존",
            .src =
            \\import { A, B } from "./lib";
            \\export function f(x: A): void { B(); }
            ,
            .verbatim = true,
            .must_contain = &.{"import { A, B } from \"./lib\""},
        },
        .{
            .name = "verbatim=true: 완전 unused named 도 보존",
            .src =
            \\import { A } from "./lib";
            \\export const x = 1;
            ,
            .verbatim = true,
            .must_contain = &.{"import { A } from \"./lib\""},
        },

        // ---------- UNUSED (Phase D 가 value-unused 도 포괄) ----------
        .{
            // named binding 이 아예 참조되지 않은 경우 — declare Reference 만 존재.
            // value read 가 없으므로 elide. value-unused 경로 검증.
            .name = "named completely unused: drop",
            .src =
            \\import { A } from "./lib";
            \\export const x = 1;
            ,
            .must_not_contain = &.{ "import", "./lib" },
        },

        // ---------- SIDE-EFFECT IMPORT: 항상 유지 ----------
        .{
            .name = "side-effect import: 항상 유지",
            .src =
            \\import "./side-effect";
            \\export const x = 1;
            ,
            .must_contain = &.{"./side-effect"},
        },

        // ---------- JSX: default import 유지 확인 (.tsx) ----------
        .{
            // JSX classic transform 은 `React.createElement` 를 주입 — React 가 value
            // 참조. Phase D 가 default 를 건드리지 않으므로 직접 드롭되지 않지만,
            // 회귀 방지 차원에서 명시 확인.
            .name = "JSX pragma: default React 는 JSX 있는 파일에서 유지",
            .src =
            \\import React from "react";
            \\export const App = () => <div />;
            ,
            .path = "input.tsx",
            .must_contain = &.{"import React from \"react\""},
        },
    };
    for (cases) |c| {
        var result = try transpile_mod.transpile(
            std.testing.allocator,
            c.src,
            c.path,
            .{ .verbatim_module_syntax = c.verbatim },
        );
        defer result.deinit(std.testing.allocator);
        for (c.must_contain) |needle| {
            std.testing.expect(std.mem.indexOf(u8, result.code, needle) != null) catch |e| {
                std.debug.print("case '{s}': expected substring '{s}' in {s}\n", .{ c.name, needle, result.code });
                return e;
            };
        }
        for (c.must_not_contain) |forbidden| {
            std.testing.expect(std.mem.indexOf(u8, result.code, forbidden) == null) catch |e| {
                std.debug.print("case '{s}': forbidden substring '{s}' found in {s}\n", .{ c.name, forbidden, result.code });
                return e;
            };
        }
    }
}

// ============================================================
// --define 치환 (#1552)
// ============================================================

test "define: optional chaining + global root prefix 매칭" {
    const Case = struct {
        name: []const u8,
        src: []const u8,
        must_contain: []const []const u8,
        must_not_contain: []const []const u8,
    };
    const defines = [_]transformer_mod.DefineEntry{
        .{ .key = "process.env.NODE_ENV", .value = "\"production\"" },
    };
    const cases = [_]Case{
        .{
            .name = "simple chain",
            .src = "const x = process.env.NODE_ENV;",
            .must_contain = &.{"\"production\""},
            .must_not_contain = &.{"process.env"},
        },
        .{
            .name = "optional chaining (?.)",
            .src = "const x = process?.env?.NODE_ENV;",
            .must_contain = &.{"\"production\""},
            .must_not_contain = &.{"?."},
        },
        .{
            .name = "globalThis + optional chaining",
            .src = "const x = globalThis.process?.env?.NODE_ENV;",
            .must_contain = &.{"\"production\""},
            .must_not_contain = &.{"globalThis"},
        },
        .{
            // anti-regression: 이름이 비슷하지만 다른 식은 치환하지 않아야.
            .name = "unrelated identifiers preserved",
            .src = "const a = process.env.PORT; const b = other.env.NODE_ENV;",
            .must_contain = &.{ "process.env.PORT", "other.env.NODE_ENV" },
            .must_not_contain = &.{"\"production\""},
        },
    };
    for (cases) |c| {
        var result = try transpile_mod.transpile(
            std.testing.allocator,
            c.src,
            "input.ts",
            .{ .define = &defines },
        );
        defer result.deinit(std.testing.allocator);
        for (c.must_contain) |needle| {
            std.testing.expect(std.mem.indexOf(u8, result.code, needle) != null) catch |e| {
                std.debug.print("case '{s}': expected substring '{s}' in {s}\n", .{ c.name, needle, result.code });
                return e;
            };
        }
        for (c.must_not_contain) |forbidden| {
            std.testing.expect(std.mem.indexOf(u8, result.code, forbidden) == null) catch |e| {
                std.debug.print("case '{s}': forbidden substring '{s}' found in {s}\n", .{ c.name, forbidden, result.code });
                return e;
            };
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// HMR regression guard
//
// 같은 parser ast 로 Transformer.init → transform 을 여러 번 호출할 때 parser
// 노드 영역이 변경되지 않음을 보장. HMR rebuild 2회차에서 stale 상태를 읽어
// Ast.getNode OOB 가 나는 시나리오 (번개 ExampleApp 1172 모듈에서 재현됨) 를
// 유닛 단에서 포착. 현재 구현은 `source_ast: *const Ast` 로 타입 레벨에서
// 보호하지만 D1 in-place 경로 재도입 시엔 이 검증이 필수다.
// ─────────────────────────────────────────────────────────────────

/// 테스트 전용 — Ast 내부 배열 bit-identical 비교용 스냅샷.
const AstSnapshot = struct {
    nodes: []Node,
    extra_data: []u32,
    string_table: []u8,

    fn take(allocator: std.mem.Allocator, ast: *const Ast) !AstSnapshot {
        return .{
            .nodes = try allocator.dupe(Node, ast.nodes.items),
            .extra_data = try allocator.dupe(u32, ast.extra_data.items),
            .string_table = try allocator.dupe(u8, ast.string_table.items),
        };
    }

    fn deinit(self: *AstSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.nodes);
        allocator.free(self.extra_data);
        allocator.free(self.string_table);
    }

    fn assertMatches(self: AstSnapshot, ast: *const Ast) !void {
        try std.testing.expectEqual(self.extra_data.len, ast.extra_data.items.len);
        try std.testing.expectEqual(self.string_table.len, ast.string_table.items.len);
        try std.testing.expectEqualSlices(u32, self.extra_data, ast.extra_data.items);
        try std.testing.expectEqualSlices(u8, self.string_table, ast.string_table.items);
        // Node 는 extern struct 라 padding 없는 bit-identical 비교 가능.
        try std.testing.expectEqualSlices(
            u8,
            std.mem.sliceAsBytes(self.nodes),
            std.mem.sliceAsBytes(ast.nodes.items),
        );
    }
};

fn runTransformTwiceAndAssertParserUnchanged(allocator: std.mem.Allocator, source: []const u8) !void {
    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var snap = try AstSnapshot.take(allocator, &parser.ast);
    defer snap.deinit(allocator);

    var t1 = try Transformer.init(allocator, &parser.ast, .{});
    _ = try t1.transform();
    t1.deinit();
    try snap.assertMatches(&parser.ast);

    // 2회차: 1회차가 오염됐다면 여기서 stale state 위에서 시작해 OOB/오답 유발.
    var t2 = try Transformer.init(allocator, &parser.ast, .{});
    _ = try t2.transform();
    t2.deinit();
    try snap.assertMatches(&parser.ast);
}

test "HMR guard: plain module — transform twice, parser ast unchanged" {
    try runTransformTwiceAndAssertParserUnchanged(
        std.testing.allocator,
        "export const x = 1; export function foo() { return x; }",
    );
}

test "HMR guard: function with default + destructuring + rest params" {
    // function parameter lowering (default/rest/destructuring) 이 parser function
    // 노드의 params/body 참조를 새 노드로 바꾸는 대표 경로.
    try runTransformTwiceAndAssertParserUnchanged(std.testing.allocator,
        \\export function foo(a = 1, [b, c], ...rest) {
        \\  const { x, y } = bar();
        \\  return a + b + c + x + y + rest.length;
        \\}
    );
}

test "HMR guard: class with private field + method" {
    // class lowering 이 method body 와 private 필드 접근을 재작성하는 경로.
    try runTransformTwiceAndAssertParserUnchanged(std.testing.allocator,
        \\export class K extends Base {
        \\  #secret = 1;
        \\  method() { return this.#secret; }
        \\  static factory(x = 1) { return new K(x); }
        \\}
    );
}

test "HMR guard: export default with function + async" {
    // default export wrapper + async 조합 — OOB 스택에 visitExportDefaultDeclaration 로 자주 등장.
    try runTransformTwiceAndAssertParserUnchanged(std.testing.allocator,
        \\export default async function main(opts = {}) {
        \\  const { count = 3, name } = opts;
        \\  for (let i = 0; i < count; i++) await work(name, i);
        \\}
    );
}

test "HMR guard: variable declaration with complex initializers" {
    // downgradeToVar / mergeDecls 가 variable_declaration 의 kind/list 를 건드리는 경로.
    try runTransformTwiceAndAssertParserUnchanged(std.testing.allocator,
        \\const x = { a: 1, b: [2, 3], c: foo() };
        \\const y = (n) => n * 2;
        \\const z = typeof x === "object";
    );
}
