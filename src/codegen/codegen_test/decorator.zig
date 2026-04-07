const std = @import("std");
const helpers = @import("helpers.zig");
const e2eDecorator = helpers.e2eDecorator;
const e2eDecoratorES5 = helpers.e2eDecoratorES5;
const e2eDecoratorMetadata = helpers.e2eDecoratorMetadata;
const e2eFull = helpers.e2eFull;
const TransformOptions = helpers.TransformOptions;
const TestResult = helpers.TestResult;

// ============================================================
// Legacy (experimental) Decorator e2e — 출력 내용 검증
// ============================================================

test "decorator: class decorator → __decorateClass" {
    var r = try e2eDecorator(std.testing.allocator, "@sealed class Foo {}");
    defer r.deinit();
    // let Foo = class Foo {};
    // Foo = __decorateClass([sealed], Foo);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__decorateClass") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "sealed") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let Foo") != null);
}

test "decorator: method decorator → __decorateClass with prototype" {
    var r = try e2eDecorator(std.testing.allocator,
        \\class Foo {
        \\  @log
        \\  greet() { return "hi"; }
        \\}
    );
    defer r.deinit();
    // __decorateClass([log], Foo.prototype, "greet", 1)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__decorateClass") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.prototype") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"greet\"") != null);
}

test "decorator: parameter decorator → __decorateParam" {
    var r = try e2eDecorator(std.testing.allocator,
        \\class Foo {
        \\  method(@inject a: number) {}
        \\}
    );
    defer r.deinit();
    // __decorateClass([__decorateParam(0, inject)], Foo.prototype, "method", 1)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__decorateParam") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "inject") != null);
}

test "decorator: multiple parameter decorators" {
    var r = try e2eDecorator(std.testing.allocator,
        \\class Foo {
        \\  method(@a x: number, @b y: string) {}
        \\}
    );
    defer r.deinit();
    // __decorateParam(0, a) + __decorateParam(1, b)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__decorateParam(0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__decorateParam(1") != null);
}

test "decorator: constructor parameter decorator" {
    var r = try e2eDecorator(std.testing.allocator,
        \\class Foo {
        \\  constructor(@inject svc: Service) {}
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__decorateParam") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "inject") != null);
}

test "decorator: class + method + param combined" {
    var r = try e2eDecorator(std.testing.allocator,
        \\@component
        \\class Ctrl {
        \\  @get("/")
        \\  index(@query q: string) {}
        \\}
    );
    defer r.deinit();
    // class decorator: __decorateClass([component], Ctrl)
    // method decorator: __decorateClass([__decorateParam(0, query), get("/")], Ctrl.prototype, "index", 1)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let Ctrl") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__decorateParam") != null);
    // class decorator가 마지막에 적용
    const class_deco_pos = std.mem.indexOf(u8, r.output, "component") orelse return error.TestUnexpectedResult;
    const method_deco_pos = std.mem.indexOf(u8, r.output, "Ctrl.prototype") orelse return error.TestUnexpectedResult;
    // method decorator가 class decorator보다 먼저 나와야 함
    try std.testing.expect(method_deco_pos < class_deco_pos);
}

test "decorator: call expression @dec(arg)" {
    var r = try e2eDecorator(std.testing.allocator,
        \\@Component({ selector: "app" })
        \\class AppComponent {}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__decorateClass") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Component") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "selector") != null);
}

test "decorator: no decorator → class preserved as-is" {
    var r = try e2eDecorator(std.testing.allocator, "class Foo { greet() {} }");
    defer r.deinit();
    // __decorateClass가 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__decorateClass") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class Foo") != null);
}

test "decorator: static method decorator" {
    var r = try e2eDecorator(std.testing.allocator,
        \\class Foo {
        \\  @log
        \\  static create() {}
        \\}
    );
    defer r.deinit();
    // static은 Foo 자체에 달림 (Foo.prototype이 아닌 Foo)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__decorateClass") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"create\"") != null);
}

test "decorator: derived class with decorators" {
    var r = try e2eDecorator(std.testing.allocator,
        \\class Base {}
        \\@sealed
        \\class Child extends Base {
        \\  @log
        \\  method() {}
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "extends Base") != null or
        std.mem.indexOf(u8, r.output, "extends") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__decorateClass") != null);
}

test "decorator: multiple decorators on class" {
    var r = try e2eDecorator(std.testing.allocator,
        \\@Injectable()
        \\@Controller("/api")
        \\class ApiController {}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Injectable") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Controller") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__decorateClass") != null);
}

// ============================================================
// ES5 + experimentalDecorators
// ============================================================

test "decorator + es5: class decorator with IIFE" {
    var r = try e2eDecoratorES5(std.testing.allocator, "@sealed class Foo {}");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__decorateClass") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "sealed") != null);
    // ES5에서는 class가 function으로 변환
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class ") == null);
}

test "decorator + es5: method decorator" {
    var r = try e2eDecoratorES5(std.testing.allocator,
        \\class Foo {
        \\  @log
        \\  greet() { return "hi"; }
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__decorateClass") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class ") == null);
}

test "decorator + es5: constructor param decorator" {
    var r = try e2eDecoratorES5(std.testing.allocator,
        \\class Foo {
        \\  constructor(@inject svc: any) {}
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__decorateParam") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class ") == null);
}

// ============================================================
// emitDecoratorMetadata — __metadata 출력 검증
// ============================================================

test "metadata: class decorator → __metadata(design:paramtypes)" {
    // 일반 파라미터 (parameter property 아닌)
    var r = try e2eDecoratorMetadata(std.testing.allocator,
        \\@Injectable()
        \\class UserService {
        \\  constructor(repo: UserRepository, logger: Logger) {}
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "design:paramtypes") != null);
    // SWC 호환: typeof X === "undefined" ? Object : X
    try std.testing.expect(std.mem.indexOf(u8, r.output, "UserRepository") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Logger") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "typeof") != null);
}

test "metadata: method decorator → design:type + design:paramtypes + design:returntype" {
    var r = try e2eDecoratorMetadata(std.testing.allocator,
        \\class Ctrl {
        \\  @Get("/")
        \\  index(@Query q: string) {}
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "design:type") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "design:paramtypes") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "design:returntype") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Function") != null);
}

test "metadata: primitive types → Number, String, Boolean" {
    var r = try e2eDecoratorMetadata(std.testing.allocator,
        \\class Foo {
        \\  @log
        \\  method(a: number, b: string, c: boolean) {}
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Number") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "String") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Boolean") != null);
}

test "metadata: no decorators → no __metadata" {
    var r = try e2eDecoratorMetadata(std.testing.allocator,
        \\class Foo {
        \\  method(a: number) {}
        \\}
    );
    defer r.deinit();
    // decorator가 없으면 __metadata도 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__metadata") == null);
}

test "metadata: emitDecoratorMetadata=false → no __metadata" {
    var r = try e2eDecorator(std.testing.allocator,
        \\@Injectable()
        \\class Foo {
        \\  constructor(private svc: Service) {}
        \\}
    );
    defer r.deinit();
    // emitDecoratorMetadata가 꺼져있으면 __metadata 없음
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__metadata") == null);
}

// ============================================================
// SWC 호환: 타입 직렬화 상세 테스트
// ============================================================

test "metadata: void/null/undefined/never → void 0 (SWC 호환)" {
    var r = try e2eDecoratorMetadata(std.testing.allocator,
        \\class Foo {
        \\  @dec method(a: void, b: null, c: undefined, d: never) {}
        \\}
    );
    defer r.deinit();
    // void/null/undefined/never는 모두 void 0으로 직렬화
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") != null);
}

test "metadata: symbol → typeof Symbol guard (SWC 호환)" {
    var r = try e2eDecoratorMetadata(std.testing.allocator,
        \\class Foo {
        \\  @dec method(a: symbol) {}
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "typeof Symbol") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object") != null);
}

test "metadata: bigint → typeof BigInt guard (SWC 호환)" {
    var r = try e2eDecoratorMetadata(std.testing.allocator,
        \\class Foo {
        \\  @dec method(a: bigint) {}
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "typeof BigInt") != null);
}

test "metadata: class reference → typeof guard (SWC 호환)" {
    var r = try e2eDecoratorMetadata(std.testing.allocator,
        \\class Foo {
        \\  @dec method(a: MyService) {}
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "typeof MyService") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"undefined\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "?") != null);
}

test "metadata: any/object/unknown → Object" {
    var r = try e2eDecoratorMetadata(std.testing.allocator,
        \\class Foo {
        \\  @dec method(a: any, b: object, c: unknown) {}
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "design:paramtypes") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object") != null);
}

test "metadata: Function type → Function" {
    var r = try e2eDecoratorMetadata(std.testing.allocator,
        \\class Foo {
        \\  @dec method(callback: Function) {}
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Function") != null);
}

test "metadata: multiple decorators on method preserve metadata" {
    var r = try e2eDecoratorMetadata(std.testing.allocator,
        \\class Ctrl {
        \\  @Get("/")
        \\  @Auth("admin")
        \\  index(q: string) {}
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "design:paramtypes") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "String") != null);
}

test "metadata: NestJS pattern — constructor DI" {
    var r = try e2eDecoratorMetadata(std.testing.allocator,
        \\@Controller()
        \\class AppController {
        \\  constructor(appService: AppService, logger: Logger) {}
        \\  @Get()
        \\  getHello(): string { return "hello"; }
        \\}
    );
    defer r.deinit();
    // class decorator에 constructor paramtypes
    try std.testing.expect(std.mem.indexOf(u8, r.output, "design:paramtypes") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "AppService") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Logger") != null);
    // method decorator에도 metadata
    try std.testing.expect(std.mem.indexOf(u8, r.output, "design:type") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "design:returntype") != null);
}

test "metadata: static method decorator" {
    var r = try e2eDecoratorMetadata(std.testing.allocator,
        \\class Foo {
        \\  @log
        \\  static create(name: string): Foo { return new Foo(); }
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "String") != null);
}

test "metadata: method with no params → empty array" {
    var r = try e2eDecoratorMetadata(std.testing.allocator,
        \\class Foo {
        \\  @log
        \\  run() {}
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "design:paramtypes") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[]") != null);
}

test "metadata: mixed primitive + class params" {
    var r = try e2eDecoratorMetadata(std.testing.allocator,
        \\class Foo {
        \\  @dec
        \\  method(id: number, name: string, svc: MyService) {}
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Number") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "String") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "MyService") != null);
}
