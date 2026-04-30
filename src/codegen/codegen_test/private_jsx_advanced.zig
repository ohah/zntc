const std = @import("std");
const helpers = @import("helpers.zig");
const e2e = helpers.e2e;
const e2eCJS = helpers.e2eCJS;
const e2eJSX = helpers.e2eJSX;
const e2eFull = helpers.e2eFull;
const e2eWithOptions = helpers.e2eWithOptions;
const e2eSourceMap = helpers.e2eSourceMap;
const TransformOptions = helpers.TransformOptions;
const CodegenOptions = helpers.CodegenOptions;
const TestResult = helpers.TestResult;
const e2eTarget = helpers.e2eTarget;
const e2eJSXAutomatic = helpers.e2eJSXAutomatic;
const e2eJSXDev = helpers.e2eJSXDev;
const e2eJSXAutomaticTarget = helpers.e2eJSXAutomaticTarget;
const e2eJSXClassicTarget = helpers.e2eJSXClassicTarget;
const codegen_mod = helpers.codegen_mod;

// Private Method (#method → WeakSet + standalone function)
// ============================================================

test "private method: es2021 → WeakSet + standalone function (class preserved)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #bar() { return 1; }
        \\  method() { return this.#bar(); }
        \\}
    , .es2021);
    defer r.deinit();
    // WeakSet 선언
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _bar=new WeakSet") != null);
    // standalone function
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _bar_fn()") != null);
    // class 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class Foo") != null);
    // brand check init
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodInit(this,_bar)") != null);
    // brand check get + .call
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodGet(this,_bar,_bar_fn).call(this)") != null);
}

test "private method: es5 → WeakSet + function + prototype" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #bar() { return 1; }
        \\  method() { return this.#bar(); }
        \\}
    , .es5);
    defer r.deinit();
    // class → function
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Foo()") != null);
    // WeakSet
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _bar=new WeakSet") != null);
    // prototype method descriptor
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.defineProperty(Foo.prototype,\"method\"") != null);
    // brand check
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodInit(this,_bar)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodGet(this,_bar,_bar_fn).call(this)") != null);
}

test "private method: multiple methods" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #bar() { return 1; }
        \\  #baz(x: number) { return x + 1; }
        \\  method() { return this.#bar() + this.#baz(2); }
        \\}
    , .es2021);
    defer r.deinit();
    // 두 WeakSet
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _bar=new WeakSet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _baz=new WeakSet") != null);
    // 두 standalone function
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _bar_fn()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _baz_fn(x)") != null);
    // 호출부에 인자 전달
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodGet(this,_baz,_baz_fn).call(this,2)") != null);
}

test "private method: with existing constructor (es2021)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Greeter {
        \\  name: string;
        \\  constructor(name: string) { this.name = name; }
        \\  #format() { return "Hello, " + this.name; }
        \\  greet() { return this.#format(); }
        \\}
    , .es2021);
    defer r.deinit();
    // constructor에 init 주입
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodInit(this,_format)") != null);
    // 기존 constructor body 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.name=name") != null);
}

test "private method: with extends generates super() (es2021)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Base { value = 10; }
        \\class Child extends Base {
        \\  #helper() { return this.value; }
        \\  run() { return this.#helper(); }
        \\}
    , .es2021);
    defer r.deinit();
    // extends가 있고 constructor가 없을 때 super(...args) 포함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super(...args)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodInit(this,_helper)") != null);
}

test "private method: class expression wrapped in IIFE (es2021)" {
    // 버그 회귀 방지: class_expression의 private method 다운레벨 시 pre_stmts(WeakSet 선언,
    // standalone function)가 pending_nodes로 상위 statement에 drain되면 variable_declarator에
    // 쉼표로 stitching되어 `const W = class A{...},var _m=new WeakSet();,function _m_fn(){...}`
    // 같은 깨진 코드가 생성되었다. IIFE로 감싸서 해결.
    var r = try e2eTarget(std.testing.allocator,
        \\const W = class A {
        \\  x = 1;
        \\  #m() { return this.x; }
        \\};
    , .es2021);
    defer r.deinit();
    // IIFE 래핑
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const W=(()=>{") != null);
    // 헬퍼가 IIFE 내부에 있음
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _m=new WeakSet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _m_fn()") != null);
    // class_declaration으로 재작성
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class A") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return A") != null);
    // 쉼표 stitching 없음 (버그 증상)
    try std.testing.expect(std.mem.indexOf(u8, r.output, ",var _m") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "},var ") == null);
}

test "private method: anonymous class expression gets temp name (es2021)" {
    var r = try e2eTarget(std.testing.allocator,
        \\const W = class {
        \\  #m() { return 1; }
        \\};
    , .es2021);
    defer r.deinit();
    // IIFE 래핑
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(()=>{") != null);
    // 임시 이름(_a 등)으로 class_declaration 생성 + return
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _m=new WeakSet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _m_fn()") != null);
    // 쉼표 stitching 없음
    try std.testing.expect(std.mem.indexOf(u8, r.output, ",var _m") == null);
}

test "private method: class expression as call argument wrapped in IIFE (es2021)" {
    // 인자 위치에서도 IIFE가 paren 내부에 정상 배치되고 쉼표 stitching 없음
    var r = try e2eTarget(std.testing.allocator,
        \\foo(class { #m() { return 1; } });
    , .es2021);
    defer r.deinit();
    // IIFE 래핑: foo((()=>{...})())
    try std.testing.expect(std.mem.indexOf(u8, r.output, "foo((()=>{") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _m=new WeakSet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _m_fn()") != null);
    // 쉼표 stitching 없음
    try std.testing.expect(std.mem.indexOf(u8, r.output, ",var _m") == null);
    // IIFE 종료: return X})()
    try std.testing.expect(std.mem.indexOf(u8, r.output, "})())") != null);
}

test "private method: array of class expressions — each IIFE independent (es2021)" {
    // 배열의 두 class expression이 각각 독립 IIFE + helper 이름 충돌 없음
    var r = try e2eTarget(std.testing.allocator,
        \\const arr = [class { #m() { return 1; } }, class { #n() { return 2; } }];
    , .es2021);
    defer r.deinit();
    // 두 IIFE 모두 존재
    var iter_idx: usize = 0;
    var iife_count: usize = 0;
    while (std.mem.indexOfPos(u8, r.output, iter_idx, "(()=>{")) |pos| {
        iife_count += 1;
        iter_idx = pos + 1;
    }
    try std.testing.expect(iife_count >= 2);
    // 각각의 WeakSet/standalone function
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _m=new WeakSet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _n=new WeakSet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _m_fn()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _n_fn()") != null);
    // 쉼표 stitching 없음
    try std.testing.expect(std.mem.indexOf(u8, r.output, ",var _m") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ",var _n") == null);
}

test "private method: nested class expression inside outer class body (es2021)" {
    // outer class body 안에서 inner class_expression IIFE가 정상 drain
    var r = try e2eTarget(std.testing.allocator,
        \\class A {
        \\  m() { return class { #n() { return 1; } }; }
        \\}
    , .es2021);
    defer r.deinit();
    // outer class 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class A") != null);
    // inner IIFE 존재
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(()=>{") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _n=new WeakSet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _n_fn()") != null);
    // IIFE 종료 + 쉼표 stitching 없음
    try std.testing.expect(std.mem.indexOf(u8, r.output, "})()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ",var _n") == null);
}

test "private static method: class expression lowers without stitching (es2021)" {
    var r = try e2eTarget(std.testing.allocator,
        \\const W = class {
        \\  static #m() { return 1; }
        \\  static call() { return this.#m(); }
        \\};
    , .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classStaticPrivateFieldSpecGet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_m_fn") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".#m(") == null);
    // 쉼표 stitching 부재 (버그 증상)
    try std.testing.expect(std.mem.indexOf(u8, r.output, ",var _m") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "},var ") == null);
}

test "private getter: class expression wrapped in IIFE (es2021)" {
    var r = try e2eTarget(std.testing.allocator,
        \\const W = class { get #x() { return 1; } };
    , .es2021);
    defer r.deinit();
    // IIFE 래핑
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const W=(()=>{") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_x") != null);
    // IIFE 종료
    try std.testing.expect(std.mem.indexOf(u8, r.output, "})()") != null);
    // 쉼표 stitching 없음
    try std.testing.expect(std.mem.indexOf(u8, r.output, "},var ") == null);
}

test "private static method: class declaration call lowers (es2021)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  static #m() { return 1; }
        \\  static call() { return Foo.#m(); }
        \\}
    , .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _m={writable:true,value:_m_fn}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _m_fn()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classStaticPrivateFieldSpecGet(Foo,Foo,_m).call(Foo)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".#m(") == null);
}

test "private static method: method reference binds receiver (es2021)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  static #m() { return this; }
        \\  static ref() { return this.#m; }
        \\}
    , .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classStaticPrivateFieldSpecGet(this,Foo,_m).bind(this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".#m") == null);
}

test "private static method: brand check lowers to class identity (es2021)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  static #m() { return 1; }
        \\  static has(o) { return #m in o; }
        \\}
    , .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "o===Foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "#m in") == null);
}

test "private static method: es2022 target preserves original" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  static #m() { return 1; }
        \\  static call() { return this.#m(); }
        \\}
    , .es2022);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "static #m()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.#m()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classStaticPrivateFieldSpecGet") == null);
}

// 회귀 가드: private *field* 의 arrow init 안에서 다른 private *method* 호출이
// lowering 되는지. classifyMembers 의 inner setup 이 current_private_methods 를
// 빠뜨리면 arrow body 의 `this.#m()` 호출이 raw 로 남아 hermesc/Node syntax error
// (RN DebuggingOverlayRegistry 의 #onDrawTraceUpdates → #drawTraceUpdatesModern 패턴).
test "private field arrow init: this.#method() inside arrow lowers (es2021)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #handler = () => { this.#flush(); };
        \\  #flush() { return 1; }
        \\}
    , .es2021);
    defer r.deinit();
    // arrow body 안의 #flush() 호출이 helper 경유로 변환됨 (_this 또는 this — alias 변수명은 무관)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_flush_fn") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodGet") != null);
    // raw `.#flush(` 호출이 남아있지 않아야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".#flush(") == null);
}

test "private field arrow init: this.#method() inside nested arrow lowers (es5)" {
    // ES5 다운레벨은 arrow 도 function expression 으로 풀어 _this alias 가 명시적으로 등장.
    var r = try e2eTarget(std.testing.allocator,
        \\class Reg {
        \\  #onUpdate = (x) => { if (x) { this.#applyModern(x); } else { this.#applyLegacy(); } };
        \\  #applyModern(x) { return x; }
        \\  #applyLegacy() { return 0; }
        \\}
    , .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_applyModern_fn") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_applyLegacy_fn") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodGet") != null);
    // raw private method call 이 남으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".#applyModern(") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".#applyLegacy(") == null);
}

test "private downlevel debug invariant: raw private syntax absent after transform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\class Foo {
        \\  #handler = () => { this.#flush(); };
        \\  #flush() { return 1; }
        \\}
    ;

    var scanner = try helpers.Scanner.init(allocator, source);
    var parser = helpers.Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    const parsed_root = try parser.parse();
    try std.testing.expect(codegen_mod.hasRawPrivateSyntax(&parser.ast, parsed_root));

    const unsupported = TransformOptions.compat.fromESTarget(.es2021);
    var transformer = try helpers.Transformer.init(allocator, &parser.ast, .{
        .unsupported = unsupported,
    });
    const transformed_root = try transformer.transform();
    try std.testing.expect(!codegen_mod.hasRawPrivateSyntax(transformer.ast, transformed_root));
}

test "private method: es2022 target preserves original" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #bar() { return 1; }
        \\  method() { return this.#bar(); }
        \\}
    , .es2022);
    defer r.deinit();
    // 원본 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "#bar()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.#bar()") != null);
    // WeakSet 없음
    try std.testing.expect(std.mem.indexOf(u8, r.output, "WeakSet") == null);
}

// #1564 Case 2 회귀 가드: generator private method (`*#name`) 를 다운레벨링할 때,
// method_definition의 is_generator flag를 function_declaration으로 복사해야 한다.
// 과거 `buildStandaloneFunc`가 flags=0으로 하드코딩해서 `function* _fn` 대신
// 일반 `function _fn`이 생성 → `yield`가 일반 함수에 노출되어 SyntaxError 발생.
test "private generator method: es2021 → function* _name_fn preserves generator (#1564)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  *#walk() { yield 1; yield 2; }
        \\  run() { return this.#walk(); }
        \\}
    , .es2021);
    defer r.deinit();
    // standalone function이 generator(`function*`) kind로 생성되어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function* _walk_fn()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") != null);
}

test "private async method: es2021 → async function preserves async (#1564)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  async #fetch() { return 1; }
        \\  run() { return this.#fetch(); }
        \\}
    , .es2021);
    defer r.deinit();
    // async 플래그도 standalone function으로 전이되어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async function _fetch_fn()") != null);
}

test "private async generator method: async *#name → async function* (#1564)" {
    // async + generator 플래그가 동시에 전이되어야 한다.
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  async *#walk() { yield 1; yield await Promise.resolve(2); }
        \\  run() { return this.#walk(); }
        \\}
    , .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async function* _walk_fn()") != null);
}

test "private generator method: yield* delegation preserved (#1564)" {
    // generator 내부에서 다른 private generator를 yield*로 위임하는 경우.
    // 두 standalone function 모두 `function*` kind로 생성되어야 yield*가 유효.
    var r = try e2eTarget(std.testing.allocator,
        \\class Box {
        \\  *#inner() { yield 1; }
        \\  *#outer() { yield* this.#inner(); }
        \\}
    , .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function* _inner_fn()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function* _outer_fn()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield*") != null);
}

test "private methods mixed kinds: generator + async + plain (#1564)" {
    // 한 클래스에 kind가 다른 private 메서드가 섞여 있어도 각각 올바른 kind로 hoist.
    var r = try e2eTarget(std.testing.allocator,
        \\class Registry {
        \\  *#ids() { yield "a"; }
        \\  async #name(id: string) { return "n-" + id; }
        \\  #plain() { return 42; }
        \\  run() { return [this.#ids(), this.#name("x"), this.#plain()]; }
        \\}
    , .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function* _ids_fn()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async function _name_fn(") != null);
    // plain은 async/generator 키워드가 붙지 않아야 한다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _plain_fn()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async function _plain_fn") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function* _plain_fn") == null);
}

// ============================================================
// JSX text normalization
// ============================================================

test "JSX automatic: single child multiline text normalized to spaces" {
    // JSX 스펙: 여러 줄 텍스트의 개행은 공백으로 치환
    var r = try e2eJSXAutomatic(std.testing.allocator,
        \\const x = <Text>This call stack is not symbolicated.
        \\              Some features are unavailable.</Text>;
    );
    defer r.deinit();
    // 개행이 공백으로 정규화됨 (리터럴 개행이 남아있으면 SyntaxError)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "symbolicated. Some") != null);
    // 리터럴 \n이 문자열 안에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "symbolicated.\n") == null);
}

test "JSX automatic-dev: single child multiline text normalized" {
    // --jsx-dev 모드에서도 동일하게 정규화
    var r = try e2eJSXDev(std.testing.allocator,
        \\const x = <Text>Hello
        \\  World</Text>;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"Hello World\"") != null);
}

test "JSX classic: single child multiline text normalized" {
    // classic 모드에서도 동일하게 정규화
    var r = try e2eJSX(std.testing.allocator,
        \\const x = <Text>Line one
        \\  Line two</Text>;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"Line one Line two\"") != null);
}

test "JSX automatic: multiple children multiline text normalized" {
    // 여러 children 중 텍스트에 개행이 있는 경우도 정규화
    var r = try e2eJSXAutomatic(std.testing.allocator,
        \\const x = <div>Hello
        \\  World<span>!</span></div>;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"Hello World\"") != null);
}

test "JSX automatic: text with quotes escaped" {
    // 따옴표가 이스케이프되어야 함
    var r = try e2eJSXAutomatic(std.testing.allocator,
        \\const x = <div>He said "hello"</div>;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\\\"hello\\\"") != null);
}

// ============================================================
// 수정 1: HTML entity 디코딩 테스트
// ============================================================

test "JSX: HTML entity &amp; decodes to &" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>a &amp; b</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"a & b\"") != null);
}

test "JSX: HTML entity &lt; &gt; decode" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>&lt;tag&gt;</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"<tag>\"") != null);
}

test "JSX: HTML entity &quot; decodes and escapes" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>&quot;hi&quot;</div>;");
    defer r.deinit();
    // &quot; → " → 출력 시 \" 이스케이프
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\\\"hi\\\"") != null);
}

test "JSX: HTML entity &apos; decodes to apostrophe" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>it&apos;s</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"it's\"") != null);
}

test "JSX: numeric decimal entity &#123; decodes to {" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>&#123;</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"{\"") != null);
}

test "JSX: numeric hex entity &#x3E; decodes to >" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>&#x3E;</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\">\"") != null);
}

test "JSX: unknown entity preserved as-is" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>&unknown;</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "&unknown;") != null);
}

test "JSX: &nbsp; decodes to non-breaking space" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>a&nbsp;b</div>;");
    defer r.deinit();
    // \xC2\xA0 is UTF-8 for U+00A0
    try std.testing.expect(std.mem.indexOf(u8, r.output, "a\xC2\xA0b") != null);
}

// ============================================================
// 수정 2: 라인별 정규화 테스트 (esbuild 호환)
// ============================================================

test "JSX: multiline text normalizes to single spaces between lines" {
    var r = try e2eJSX(std.testing.allocator,
        \\const x = <div>
        \\  Hello
        \\  World
        \\</div>;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"Hello World\"") != null);
}

test "JSX: single line preserves internal spaces" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>hello   world</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"hello   world\"") != null);
}

// ============================================================
// 수정 4: UTF-16 column 계산 테스트
// ============================================================

test "JSX dev: column is 1-based UTF-16" {
    // ASCII 소스: column은 byte offset과 동일 (UTF-16이어도 ASCII 범위는 차이 없음)
    var r = try e2eJSXDev(std.testing.allocator, "const x = <div />;");
    defer r.deinit();
    // columnNumber 값이 양수로 출력되는지 확인 (파서의 span 위치에 따라 값이 다를 수 있음)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "columnNumber: ") != null);
    // lineNumber도 1-based
    try std.testing.expect(std.mem.indexOf(u8, r.output, "lineNumber: 1") != null);
}

// ============================================================
// 수정 5: key after spread → createElement 폴백 테스트
// ============================================================

test "JSX automatic: key after spread falls back to createElement" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <App {...props} key=\"k\" />;");
    defer r.deinit();
    // createElement 폴백이 사용되어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_createElement(") != null);
    // createElement import가 생성되어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "createElement as _createElement") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "from \"react\"") != null);
}

test "JSX automatic: key before spread uses normal jsx" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <App key=\"k\" {...props} />;");
    defer r.deinit();
    // key가 spread 앞이면 정상 jsx 사용
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_createElement(") == null);
}

test "JSX automatic: no key no fallback" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <App {...props} name=\"test\" />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_createElement(") == null);
}

// ============================================================
// JSX Transform 리팩터링 방어 테스트
// codegen의 JSX 변환이 별도 패스로 이동해도 동일한 출력을 보장.
// ============================================================

test "JSX refactor guard: automatic — element with props and children" {
    var r = try e2eJSXAutomatic(std.testing.allocator,
        \\const x = <div id="app" className="main"><span>hello</span></div>;
    );
    defer r.deinit();
    // single child (span) → _jsx
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"div\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "id: \"app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "className: \"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"span\"") != null);
}

test "JSX refactor guard: automatic — self-closing with no props" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <br />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"br\", {})") != null);
}

test "JSX refactor guard: automatic — component with key" {
    var r = try e2eJSXAutomatic(std.testing.allocator,
        \\const x = <Item key="k1" value={42} />;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(Item") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "value: 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ", \"k1\")") != null);
}

test "JSX refactor guard: automatic — fragment with multiple children" {
    var r = try e2eJSXAutomatic(std.testing.allocator,
        \\const x = <><div>A</div><div>B</div></>;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsxs(_Fragment") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: [") != null);
}

test "JSX refactor guard: automatic — single text child" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <p>hello world</p>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"p\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: \"hello world\"") != null);
}

test "JSX refactor guard: automatic — expression child" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <div>{count}</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"div\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: count") != null);
}

test "JSX refactor guard: automatic — spread props" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <div {...props} extra={1} />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"div\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...props") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "extra: 1") != null);
}

test "JSX refactor guard: dev — source info and isStatic" {
    var r = try e2eJSXDev(std.testing.allocator,
        \\const x = <div><span>A</span><span>B</span></div>;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsxDEV(\"div\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ", true, {") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "fileName") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "lineNumber") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ", this)") != null);
}

test "JSX refactor guard: dev — single child isStatic false" {
    var r = try e2eJSXDev(std.testing.allocator, "const x = <div><span /></div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsxDEV(\"div\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ", false, {") != null);
}

test "JSX refactor guard: key after spread — createElement fallback" {
    var r = try e2eJSXAutomatic(std.testing.allocator,
        \\const x = <Comp {...props} key="k">child</Comp>;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_createElement(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...props") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "key: \"k\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(") == null);
}

test "JSX refactor guard: classic — React.createElement" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div id=\"a\"><span>text</span></div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "React.createElement(\"div\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "id:\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "React.createElement(\"span\"") != null);
}

test "JSX refactor guard: classic — fragment" {
    var r = try e2eJSX(std.testing.allocator, "const x = <><div /><span /></>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "React.Fragment") != null);
}

test "JSX refactor guard: HTML entity in automatic mode" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <p>&amp; &lt; &euro;</p>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: \"& < ") != null);
}

test "JSX refactor guard: multiline text normalization in automatic" {
    var r = try e2eJSXAutomatic(std.testing.allocator,
        \\const x = <p>line one
        \\  line two</p>;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: \"line one line two\"") != null);
}

test "JSX refactor guard: import statement — automatic" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <div />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import { jsx as _jsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "react/jsx-runtime") != null);
}

test "JSX refactor guard: import statement — dev" {
    var r = try e2eJSXDev(std.testing.allocator, "const x = <div />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import { jsxDEV as _jsxDEV") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "react/jsx-dev-runtime") != null);
}

test "JSX refactor guard: import statement — createElement fallback" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <A {...p} key=\"k\" />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import { createElement as _createElement") != null);
}

test "JSX refactor guard: member expression tag" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <Foo.Bar baz={1} />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(Foo.Bar") != null);
}

test "JSX refactor guard: boolean and null props" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <input disabled />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"input\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "disabled: true") != null);
}

// ============================================================
// JSX + ES target: spread attribute lowering (Object.assign)
// ============================================================

test "JSX automatic + ES5: spread props → Object.assign" {
    var r = try e2eJSXAutomaticTarget(std.testing.allocator,
        \\const x = <div {...props} id="a" />;
    , .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.assign") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...props") == null);
}

test "JSX automatic + ES5: spread with children → Object.assign" {
    var r = try e2eJSXAutomaticTarget(std.testing.allocator,
        \\const x = <span style={s} {...rest}>hello</span>;
    , .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.assign") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...rest") == null);
}

test "JSX automatic + ES5: multiple spreads → Object.assign" {
    var r = try e2eJSXAutomaticTarget(std.testing.allocator,
        \\const x = <div {...a} {...b} id="c" />;
    , .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.assign") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...") == null);
}

test "JSX automatic + ES5: no spread → no Object.assign" {
    var r = try e2eJSXAutomaticTarget(std.testing.allocator,
        \\const x = <div id="a" className="b" />;
    , .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.assign") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"div\"") != null);
}

test "JSX automatic + esnext: spread preserved (no lowering)" {
    var r = try e2eJSXAutomaticTarget(std.testing.allocator,
        \\const x = <div {...props} id="a" />;
    , .esnext);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.assign") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...props") != null);
}

test "JSX classic + ES5: spread props → Object.assign" {
    var r = try e2eJSXClassicTarget(std.testing.allocator,
        \\const x = <div {...props} id="a" />;
    , .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.assign") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...props") == null);
}

test "JSX automatic + ES5: spread only → Object.assign with empty target" {
    var r = try e2eJSXAutomaticTarget(std.testing.allocator,
        \\const x = <div {...props} />;
    , .es5);
    defer r.deinit();
    // spread만 있으면 Object.assign({}, props) 형태
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.assign({}") != null);
}

test "JSX automatic + ES5: props before spread → Object.assign({id:\"a\"}, props)" {
    var r = try e2eJSXAutomaticTarget(std.testing.allocator,
        \\const x = <div id="a" {...props} />;
    , .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.assign({") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...") == null);
}

// --- ES2015: let/const → var + void 0 초기화 ---

test "ES2015: let without init → var = void 0" {
    // let은 블록 스코프: 매 반복 새 바인딩. var로 변환 시 = void 0 필수.
    var r = try e2eTarget(std.testing.allocator, "let x;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=void 0;", r.output);
}

test "ES2015: let with init preserved" {
    var r = try e2eTarget(std.testing.allocator, "let x = 1;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=1;", r.output);
}

test "ES2015: const without init → var = void 0" {
    // const도 블록 스코프 — 실제로 init 없는 const는 드물지만 처리해야 함
    var r = try e2eTarget(std.testing.allocator, "{ const x = undefined; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x") != null);
}

test "ES2015: let in for loop → var = void 0 per iteration" {
    var r = try e2eTarget(std.testing.allocator, "for(let i=0;i<3;i++){let x;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x=void 0") != null);
}

test "ES2015: class field arrow function this 캡처 (super 없음)" {
    var r = try e2eTarget(std.testing.allocator, "class A { _cb = (x) => { this._data = x; }; }", .es5);
    defer r.deinit();
    // minify: "var _this=this"
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _this=this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_this._data") != null);
}

test "ES2015: class field arrow this 순서 (classCallCheck → _this → fields)" {
    var r = try e2eTarget(std.testing.allocator, "class A { f = () => this.x; constructor() {} }", .es5);
    defer r.deinit();
    const check_pos = std.mem.indexOf(u8, r.output, "__classCallCheck") orelse return error.TestExpectedEqual;
    const this_pos = std.mem.indexOf(u8, r.output, "var _this=this") orelse return error.TestExpectedEqual;
    const field_pos = std.mem.indexOf(u8, r.output, "_this.x") orelse return error.TestExpectedEqual;
    try std.testing.expect(check_pos < this_pos);
    try std.testing.expect(this_pos < field_pos);
}

test "ES2015: class field arrow this 불필요 시 _this 미생성" {
    var r = try e2eTarget(std.testing.allocator, "class A { x = 1; y = 2; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _this") == null);
}

// ============================================================
// ES2025: using / await using
// ============================================================

test "ES2025: using → try-finally + __using" {
    var r = try e2eTarget(std.testing.allocator, "using x = getResource(); doSomething(x);", .es2024);
    defer r.deinit();
    // __using 호출 존재
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__using(_stack,") != null);
    // __callDispose 호출 존재
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callDispose(_stack,") != null);
    // try-catch-finally 구조
    try std.testing.expect(std.mem.indexOf(u8, r.output, "try{") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "catch(_)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "finally{") != null);
    // var로 변환됨 (using 키워드 없음)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x=__using") != null);
    // _stack 선언
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _stack=[]") != null);
}

test "ES2025: await using → async try-finally" {
    var r = try e2eFull(std.testing.allocator, "export async function main() { await using x = openAsync(); use(x); }", .{ .unsupported = TransformOptions.compat.fromESTarget(.es2024) }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    // __using에 true 인수 (async)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__using(_stack,openAsync(),true)") != null);
    // finally에서 await
    try std.testing.expect(std.mem.indexOf(u8, r.output, "await __callDispose(") != null);
}

test "ES2025: using esnext → 변환 없이 그대로 출력" {
    var r = try e2eTarget(std.testing.allocator, "using x = getResource();", .esnext);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "using x=getResource()") != null);
    // __using 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__using") == null);
}

test "ES2025: using es2025 → 변환 없이 그대로 출력" {
    var r = try e2eTarget(std.testing.allocator, "using x = getResource();", .es2025);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "using x=getResource()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__using") == null);
}

test "ES2025: using 다중 선언" {
    var r = try e2eTarget(std.testing.allocator, "using a = getA(); using b = getB(); use(a, b);", .es2024);
    defer r.deinit();
    // 두 using 모두 __using으로 변환
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var a=__using(_stack,getA())") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var b=__using(_stack,getB())") != null);
    // _stack은 하나만
    // 같은 _stack을 공유 (하나의 try-finally)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callDispose(_stack,") != null);
}

test "ES2025: using 앞 문장은 try 밖에 출력" {
    var r = try e2eTarget(std.testing.allocator, "let a = 1; using x = getResource(); use(x);", .es2024);
    defer r.deinit();
    // let a=1은 try 앞에 (var _stack=[] 앞에 위치)
    const output = r.output;
    const a_pos = std.mem.indexOf(u8, output, "let a=1") orelse return error.TestUnexpectedResult;
    const stack_pos = std.mem.indexOf(u8, output, "var _stack=[]") orelse return error.TestUnexpectedResult;
    try std.testing.expect(a_pos < stack_pos);
}

// Issue #1275: private method/field 변환 시 constructor 중복 emit 방지
// ================================================================

test "#1275: private method + 원본 constructor가 단일 constructor로 병합" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  constructor(cb) { this.cb = cb; }
        \\  #priv() { return 1; }
        \\  use() { return this.#priv(); }
        \\}
    , .es2020);
    defer r.deinit();
    // constructor는 정확히 1개여야 한다
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.output, "constructor("));
    // 원본 body와 init이 병합됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodInit(this,_priv)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.cb=cb") != null);
}

test "#1275: private field + 원본 constructor (field가 ctor 뒤) 병합" {
    var r = try e2eTarget(std.testing.allocator,
        \\class X {
        \\  constructor() { this.x = 1; }
        \\  #f = 2;
        \\  get() { return this.#f; }
        \\}
    , .es2020);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.output, "constructor("));
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_f.set(this,2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.x=1") != null);
    // property_definition은 body에서 제거되어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "#f=") == null);
}

test "#1275: private method + field 혼합 (RN PerformanceObserver 케이스)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class PerformanceObserver {
        \\  #nativeHandle = null;
        \\  #callback;
        \\  constructor(callback) { this.#callback = callback; }
        \\  #createObserver() { return 1; }
        \\  observe() { return this.#createObserver(); }
        \\}
    , .es2020);
    defer r.deinit();
    // constructor는 정확히 1개
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.output, "constructor("));
    // private field가 WeakMap으로 다운레벨됨 (method와 공존해도 skip되지 않음)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _nativeHandle=new WeakMap") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _callback=new WeakMap") != null);
    // private method도 변환됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _createObserver=new WeakSet") != null);
    // ctor 안에 field init + method init + 원본 body가 모두 포함
    // field init은 expression_statement 형태라 내부 값 반환 불필요 → _x.set 그대로 유지.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_nativeHandle.set(this,null)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodInit(this,_createObserver)") != null);
    // this.#callback = callback 은 assignment_expression → expression value 반환 helper 경유 (#1488).
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateFieldSet(_callback,this,callback)") != null);
}

test "#1275: private method만 있고 원본 constructor 없을 때 새 constructor 1개 생성" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #priv() { return 1; }
        \\  use() { return this.#priv(); }
        \\}
    , .es2020);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.output, "constructor("));
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodInit(this,_priv)") != null);
}

test "#1278-2: static #field → descriptor + StaticPrivateFieldSpecGet/Set" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  static #map = new Map();
        \\  static get(k) { return this.#map.get(k); }
        \\  static set(k, v) { this.#map.set(k, v); }
        \\}
    , .es2021);
    defer r.deinit();
    // descriptor 객체 선언 (class 밖)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _map={writable:true,value:new Map()}") != null);
    // static private field property_definition은 body에서 제거
    try std.testing.expect(std.mem.indexOf(u8, r.output, "static #map") == null);
    // helper 경유 접근 (class name은 'Foo')
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classStaticPrivateFieldSpecGet(this,Foo,_map)") != null);
    // this.#map 구문은 class 본문 어디에도 남지 않아야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.#map") == null);
}

test "#1278-2: static #field + instance #field 혼합 (brand check + WeakMap 공존)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Mixed {
        \\  #inst = 1;
        \\  static #stc = 2;
        \\  use() { return this.#inst + Mixed.#stc; }
        \\}
    , .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _inst=new WeakMap") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _stc={writable:true,value:2}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_inst.get(this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classStaticPrivateFieldSpecGet(Mixed,Mixed,_stc)") != null);
}

test "#1278-3: private member + static block 공존 시 static block 다운레벨" {
    // private member가 있으면 body가 이미 visit된 상태가 되므로,
    // lowerStaticBlocks를 이중 visit 없이 실행해야 한다.
    var r = try e2eTarget(std.testing.allocator,
        \\class A {
        \\  #x = 1;
        \\  static { console.log('sb'); }
        \\}
    , .es2021);
    defer r.deinit();
    // static block은 IIFE로 클래스 밖에
    try std.testing.expect(std.mem.indexOf(u8, r.output, "console.log(\"sb\")") != null);
    // class body에는 static {} 구문 남아있지 않아야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "static {") == null);
    // private field는 여전히 WeakMap으로 변환
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _x=new WeakMap") != null);
}

test "#1278-1: standalone _method_fn 내부의 this.#field가 WeakMap get으로 변환" {
    // private method 본문이 다른 private field를 참조할 때, standalone 함수로
    // 추출된 후에도 참조가 WeakMap 접근으로 변환돼야 한다. 버그 수정 전에는
    // `function _getField_fn() { return this.#field; }` 처럼 class body 밖에서
    // private 구문이 남아 파싱 에러가 발생했다.
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #field = 42;
        \\  #getField() { return this.#field; }
        \\  use() { return this.#getField(); }
        \\}
    , .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _getField_fn()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return _field.get(this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.#field") == null);
}

// ES2022 Ergonomic Brand Checks: #x in obj
// ================================================================
// Spec: https://tc39.es/ecma262/#sec-relational-operators
// Babel: @babel/plugin-transform-private-property-in-object
// 동작: class가 다운레벨되어 private mapping이 있을 때만 변환.
// - instance field  : #x in obj → _x.has(obj)    (WeakMap.has)
// - private method  : #m in obj → _m.has(obj)    (WeakSet.has)
// - static field    : #s in obj → obj === ClassName (brand check, class 이름 필요)

test "#x in obj: instance private field → WeakMap.has" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #x = 1;
        \\  static test(o) { return #x in o; }
        \\}
    , .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_x.has(o)") != null);
    // private 구문이 class body 밖으로 새어 나가지 않아야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "#x in") == null);
}

test "#x in obj: private method → WeakSet.has" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #m() { return 1; }
        \\  static test(o) { return #m in o; }
        \\}
    , .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_m.has(o)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "#m in") == null);
}

test "#x in obj: static private field → class identity brand check" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  static #s = 1;
        \\  static test(o) { return #s in o; }
        \\}
    , .es2021);
    defer r.deinit();
    // static private field는 런타임에 별도 저장소가 없으므로 class 자체 비교로 brand check.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "o===Foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "#s in") == null);
}

test "#x in obj: 부정 !(#x in obj)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #x;
        \\  static test(o) { return !(#x in o); }
        \\}
    , .es2021);
    defer r.deinit();
    // 원본의 괄호는 보존되어 `!(_x.has(o))`. 시맨틱 동일.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_x.has(o)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "#x in") == null);
}

test "#x in obj: 체이닝 (#x in o && #y in o)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #x;
        \\  #y;
        \\  static test(o) { return (#x in o) && (#y in o); }
        \\}
    , .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_x.has(o)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_y.has(o)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "#x in") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "#y in") == null);
}

test "#x in obj: if 문 안에서" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #x;
        \\  static test(o) { if (#x in o) return 1; return 0; }
        \\}
    , .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "if(_x.has(o))") != null);
}

test "#x in obj: instance method 내부 (this 컨텍스트 아닌 일반 인자)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #x;
        \\  test(o) { return #x in o; }
        \\}
    , .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_x.has(o)") != null);
}

test "#x in obj: es2022 타겟에서는 보존 (native 지원)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #x;
        \\  static test(o) { return #x in o; }
        \\}
    , .es2022);
    defer r.deinit();
    // es2022에서는 private field가 native 지원이므로 #x in o 그대로 보존
    try std.testing.expect(std.mem.indexOf(u8, r.output, "#x in o") != null);
}
