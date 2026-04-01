import { describe, test, expect } from "bun:test";
import { createFixture, runZts } from "../helpers";

async function expectPass(code: string) {
  const fixture = await createFixture({ "input.ts": code });
  try {
    const result = await runZts(["--experimental-decorators", `${fixture.dir}/input.ts`]);
    expect(result.exitCode).toBe(0);
    expect(result.stderr).not.toContain("error:");
  } finally {
    await fixture.cleanup();
  }
}

async function expectError(code: string) {
  const fixture = await createFixture({ "input.ts": code });
  try {
    const result = await runZts(["--experimental-decorators", `${fixture.dir}/input.ts`]);
    // 에러 복구로 exit code 0이 나올 수 있으므로 stderr에 error 포함 여부로 판단
    const hasError = result.exitCode !== 0 || result.stderr.includes("error");
    expect(hasError).toBe(true);
  } finally {
    await fixture.cleanup();
  }
}

describe("TSC decorator conformance", () => {
  // ---------------------------------------------------------------------------
  // Class decorators
  // ---------------------------------------------------------------------------
  describe("class decorator", () => {
    test("decoratorOnClass1 - basic class decorator", async () => {
      await expectPass(`
declare function dec<T>(target: T): T;

@dec
class C {
}`);
    });

    test("decoratorOnClass2 - exported class decorator", async () => {
      await expectPass(`
declare function dec<T>(target: T): T;

@dec
export class C {
}`);
    });

    test("decoratorOnClass4 - decorator factory on class", async () => {
      await expectPass(`
declare function dec(): <T>(target: T) => T;

@dec()
class C {
}`);
    });

    test("decoratorOnClass5 - decorator factory on class (duplicate of 4)", async () => {
      await expectPass(`
declare function dec(): <T>(target: T) => T;

@dec()
class C {
}`);
    });

    test("decoratorOnClass9 - decorator with static fields and extends", async () => {
      await expectPass(`
declare var dec: any;

class A {}

@dec
class B extends A {
    static x = 1;
    static y = B.x;
    m() {
        return B.x;
    }
}`);
    });

    test("constructableDecoratorOnClass01", async () => {
      await expectPass(`
class CtorDtor {}

@CtorDtor
class C {

}`);
    });

    test("decoratedBlockScopedClass1 - decorator with static method", async () => {
      await expectPass(`
function decorator() {
    return (target: new (...args: any[]) => any) => {}
}

@decorator()
class Foo {
    public static func(): Foo {
        return new Foo();
    }
}
Foo.func();`);
    });

    test("decoratedBlockScopedClass2 - decorator inside try block", async () => {
      await expectPass(`
function decorator() {
    return (target: new (...args: any[]) => any) => {}
}

try {
    @decorator()
    class Foo {
        public static func(): Foo {
            return new Foo();
        }
    }
    Foo.func();
}
catch (e) {}`);
    });

    test("decoratedBlockScopedClass3 - decorator top-level and in try block", async () => {
      await expectPass(`
function decorator() {
    return (target: new (...args: any[]) => any) => {}
}

@decorator()
class Foo {
    public static func(): Foo {
        return new Foo();
    }
}
Foo.func();

try {
    @decorator()
    class Foo {
        public static func(): Foo {
            return new Foo();
        }
    }
    Foo.func();
}
catch (e) {}`);
    });

    test("decoratedClassExportsCommonJS1 - exported with static props", async () => {
      await expectPass(`
declare function forwardRef(x: any): any;
declare var Something: any;
@Something({ v: () => Testing123 })
export class Testing123 {
    static prop0: string;
    static prop1 = Testing123.prop0;
}`);
    });

    test("decoratedClassExportsCommonJS2 - exported simple", async () => {
      await expectPass(`
declare function forwardRef(x: any): any;
declare var Something: any;
@Something({ v: () => Testing123 })
export class Testing123 { }`);
    });

    test("decoratedClassExportsSystem1 - system module with static props", async () => {
      await expectPass(`
declare function forwardRef(x: any): any;
declare var Something: any;
@Something({ v: () => Testing123 })
export class Testing123 {
    static prop0: string;
    static prop1 = Testing123.prop0;
}`);
    });

    test("decoratedClassExportsSystem2 - system module simple", async () => {
      await expectPass(`
declare function forwardRef(x: any): any;
declare var Something: any;
@Something({ v: () => Testing123 })
export class Testing123 { }`);
    });

    test("decoratorChecksFunctionBodies - inline decorator expression", async () => {
      await expectPass(`
function func(s: string): void {
}

class A {
    @((x, p, d) => {
        var a = 3;
        func(a);
        return d;
    })
    m() {

    }
}`);
    });

    test("decoratorCallGeneric - generic interface constraint", async () => {
      await expectPass(`
interface I<T> {
    prototype: T,
    m: () => T
}
function dec<T>(c: I<T>) { }

@dec
class C {
    _brand: any;
    static m() {}
}`);
    });

    test("decoratorInAmbientContext - declare property with decorator", async () => {
      await expectPass(`
declare function decorator(target: any, key: any): any;

const b = Symbol('b');
class Foo {
    @decorator declare a: number;
    @decorator declare [b]: number;
}`);
    });

    test("legacyDecorators-contextualTypes - inline arrow decorators", async () => {
      await expectPass(`
@((t) => { })
class C {
    constructor(@((t, k, i) => {}) p: any) {}

    @((t, k, d) => { })
    static f() {}

    @((t, k, d) => { })
    static get x() { return 1; }
    static set x(value) { }

    @((t, k, d) => { })
    static accessor y = 1;

    @((t, k) => { })
    static z = 1;

    @((t, k, d) => { })
    g() {}

    @((t, k, d) => { })
    get a() { return 1; }
    set a(value) { }

    @((t, k, d) => { })
    accessor b = 1;

    @((t, k) => { })
    c = 1;

    static h(@((t, k, i) => {}) p: any) {}
    h(@((t, k, i) => {}) p: any) {}
}`);
    });

    test("missingDecoratorType - missing lib types", async () => {
      await expectPass(`
interface Object { }
interface Array<T> { }
interface String { }
interface Boolean { }
interface Number { }
interface Function { }
interface RegExp { }
interface IArguments { }

declare function dec(t, k, d);

class C {
    @dec
    method() {}
}`);
    });
  });

  // ---------------------------------------------------------------------------
  // Constructor decorators
  // ---------------------------------------------------------------------------
  describe("constructor decorator", () => {
    test("decoratorOnClassConstructor1 - decorator on constructor (error in TSC too)", async () => {
      await expectPass(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class C {
    @dec constructor() {}
}`);
    });

    test("decoratorOnClassConstructor4 - metadata on classes with/without constructor", async () => {
      await expectPass(`
declare var dec: any;

@dec
class A {
}

@dec
class B {
    constructor(x: number) {}
}

@dec
class C extends A {
}`);
    });
  });

  // ---------------------------------------------------------------------------
  // Constructor parameter decorators
  // ---------------------------------------------------------------------------
  describe("constructor parameter decorator", () => {
    test("decoratorOnClassConstructorParameter1 - basic param decorator", async () => {
      await expectPass(`
declare function dec(target: Function, propertyKey: string | symbol, parameterIndex: number): void;

class C {
    constructor(@dec p: number) {}
}`);
    });

    test("decoratorOnClassConstructorParameter5 - static fields + param decorator", async () => {
      await expectPass(`
interface IFoo { }
declare const IFoo: any;
class BulkEditPreviewProvider {
    static readonly Schema = 'vscode-bulkeditpreview';
    static emptyPreview = { scheme: BulkEditPreviewProvider.Schema };
    constructor(
        @IFoo private readonly _modeService: IFoo,
    ) { }
}`);
    });
  });

  // ---------------------------------------------------------------------------
  // Accessor decorators
  // ---------------------------------------------------------------------------
  describe("accessor decorator", () => {
    test("decoratorOnClassAccessor1 - get accessor", async () => {
      await expectPass(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class C {
    @dec get accessor() { return 1; }
}`);
    });

    test("decoratorOnClassAccessor2 - public get accessor", async () => {
      await expectPass(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class C {
    @dec public get accessor() { return 1; }
}`);
    });

    test("decoratorOnClassAccessor4 - set accessor", async () => {
      await expectPass(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class C {
    @dec set accessor(value: number) { }
}`);
    });

    test("decoratorOnClassAccessor5 - public set accessor", async () => {
      await expectPass(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class C {
    @dec public set accessor(value: number) { }
}`);
    });

    test("decoratorOnClassAccessor7 - multiple classes with get/set pairs", async () => {
      await expectPass(`
declare function dec1<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;
declare function dec2<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class A {
    @dec1 get x() { return 0; }
    set x(value: number) { }
}

class B {
    get x() { return 0; }
    @dec2 set x(value: number) { }
}

class C {
    @dec1 set x(value: number) { }
    get x() { return 0; }
}

class D {
    set x(value: number) { }
    @dec2 get x() { return 0; }
}

class E {
    @dec1 get x() { return 0; }
    @dec2 set x(value: number) { }
}

class F {
    @dec1 set x(value: number) { }
    @dec2 get x() { return 0; }
}`);
    });

    test("decoratorOnClassAccessor8 - metadata on get/set pairs", async () => {
      await expectPass(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class A {
    @dec get x() { return 0; }
    set x(value: number) { }
}

class B {
    get x() { return 0; }
    @dec set x(value: number) { }
}

class C {
    @dec set x(value: number) { }
    get x() { return 0; }
}

class D {
    set x(value: number) { }
    @dec get x() { return 0; }
}

class E {
    @dec get x() { return 0; }
}

class F {
    @dec set x(value: number) { }
}`);
    });
  });

  // ---------------------------------------------------------------------------
  // Method decorators
  // ---------------------------------------------------------------------------
  describe("method decorator", () => {
    test("decoratorOnClassMethod1 - basic method", async () => {
      await expectPass(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class C {
    @dec method() {}
}`);
    });

    test("decoratorOnClassMethod2 - public method", async () => {
      await expectPass(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class C {
    @dec public method() {}
}`);
    });

    test("decoratorOnClassMethod4 - computed string name", async () => {
      await expectPass(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class C {
    @dec ["method"]() {}
}`);
    });

    test("decoratorOnClassMethod5 - computed name with factory", async () => {
      await expectPass(`
declare function dec(): <T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>) => TypedPropertyDescriptor<T>;

class C {
    @dec() ["method"]() {}
}`);
    });

    test("decoratorOnClassMethod6 - computed name without call", async () => {
      await expectPass(`
declare function dec(): <T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>) => TypedPropertyDescriptor<T>;

class C {
    @dec ["method"]() {}
}`);
    });

    test("decoratorOnClassMethod7 - public computed name", async () => {
      await expectPass(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class C {
    @dec public ["method"]() {}
}`);
    });

    test("decoratorOnClassMethod8 - wrong signature type", async () => {
      await expectPass(`
declare function dec<T>(target: T): T;

class C {
    @dec method() {}
}`);
    });

    test("decoratorOnClassMethod10 - wrong param count", async () => {
      await expectPass(`
declare function dec(target: Function, paramIndex: number): void;

class C {
    @dec method() {}
}`);
    });

    test("decoratorOnClassMethod11 - this expression in decorator", async () => {
      await expectPass(`
namespace M {
    class C {
        decorator(target: Object, key: string): void { }

        @(this.decorator)
        method() { }
    }
}`);
    });

    test("decoratorOnClassMethod13 - computed string keys", async () => {
      await expectPass(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class C {
    @dec ["1"]() { }
    @dec ["b"]() { }
}`);
    });

    test("decoratorOnClassMethod14 - private prop arrow then decorated method", async () => {
      await expectPass(`
declare var decorator: any;

class Foo {
    private prop = () => {
        return 0;
    }
    @decorator
    foo() {
        return 0;
    }
}`);
    });

    test("decoratorOnClassMethod15 - private prop value then decorated method", async () => {
      await expectPass(`
declare var decorator: any;

class Foo {
    private prop = 1
    @decorator
    foo() {
        return 0;
    }
}`);
    });

    test("decoratorOnClassMethod16 - private prop no initializer then decorated method", async () => {
      await expectPass(`
declare var decorator: any;

class Foo {
    private prop
    @decorator
    foo() {
        return 0;
    }
}`);
    });

    test("decoratorOnClassMethod18 - property then decorated property", async () => {
      await expectPass(`
declare var decorator: any;

class Foo {
    p1

    @decorator()
    p2;
}`);
    });

    test("decoratorOnClassMethod19 - private field with decorator using private access", async () => {
      await expectPass(`
declare var decorator: any;

class C1 {
    #x

    @decorator((x: C1) => x.#x)
    y() {}
}

class C2 {
    #x

    y(@decorator((x: C2) => x.#x) p) {}
}`);
    });

    test("decoratorOnClassMethodOverload1 - decorator on first overload", async () => {
      await expectPass(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class C {
    @dec
    method()
    method() { }
}`);
    });

    test("decoratorOnClassMethodOverload2 - decorator on second overload", async () => {
      await expectPass(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class C {
    method()
    @dec
    method() { }
}`);
    });
  });

  // ---------------------------------------------------------------------------
  // Method parameter decorators
  // ---------------------------------------------------------------------------
  describe("method parameter decorator", () => {
    test("decoratorOnClassMethodParameter1 - basic param", async () => {
      await expectPass(`
declare function dec(target: Object, propertyKey: string | symbol, parameterIndex: number): void;

class C {
    method(@dec p: number) {}
}`);
    });

    test("decoratorOnClassMethodParameter2 - this param with decorator", async () => {
      await expectPass(`
declare function dec(target: Object, propertyKey: string | symbol, parameterIndex: number): void;

class C {
    method(this: C, @dec p: number) {}
}`);
    });
  });

  // ---------------------------------------------------------------------------
  // Property decorators
  // ---------------------------------------------------------------------------
  describe("property decorator", () => {
    test("decoratorOnClassProperty1 - basic property", async () => {
      await expectPass(`
declare function dec(target: any, propertyKey: string): void;

class C {
    @dec prop;
}`);
    });

    test("decoratorOnClassProperty2 - public property", async () => {
      await expectPass(`
declare function dec(target: any, propertyKey: string): void;

class C {
    @dec public prop;
}`);
    });

    test("decoratorOnClassProperty6 - wrong signature (Function)", async () => {
      await expectPass(`
declare function dec(target: Function): void;

class C {
    @dec prop;
}`);
    });

    test("decoratorOnClassProperty7 - wrong param count signature", async () => {
      await expectPass(`
declare function dec(target: Function, propertyKey: string | symbol, paramIndex: number): void;

class C {
    @dec prop;
}`);
    });

    test("decoratorOnClassProperty10 - factory on property", async () => {
      await expectPass(`
declare function dec(): <T>(target: any, propertyKey: string) => void;

class C {
    @dec() prop;
}`);
    });

    test("decoratorOnClassProperty11 - decorator without call on property", async () => {
      await expectPass(`
declare function dec(): <T>(target: any, propertyKey: string) => void;

class C {
    @dec prop;
}`);
    });

    test("decoratorOnClassProperty12 - template literal type property", async () => {
      await expectPass(`
declare function dec(): <T>(target: any, propertyKey: string) => void;

class A {
    @dec()
    foo: \`\${string}\`
}`);
    });

    test("decoratorOnClassProperty13 - accessor keyword property", async () => {
      await expectPass(`
declare function dec(target: any, propertyKey: string, desc: PropertyDescriptor): void;

class C {
    @dec accessor prop;
}`);
    });
  });

  // ---------------------------------------------------------------------------
  // Multi-file cases (converted to single file)
  // ---------------------------------------------------------------------------
  describe("multi-file cases", () => {
    test("decoratorOnClassConstructor2 - extends with param decorator", async () => {
      await expectPass(`
class base {}
function foo(target: Object, propertyKey: string | symbol, parameterIndex: number) {}
class C extends base {
    constructor(@foo prop: any) { super(); }
}`);
    });

    test("decoratedClassFromExternalModule", async () => {
      await expectPass(`
function decorate(target: any) {}
@decorate
class Decorated {}`);
    });

    test("decoratorInstantiateModulesInFunctionBodies", async () => {
      await expectPass(`
var test = "abc";
function filter(handler: any) {
    return function(target: any, propertyKey: string) {};
}
class Wat {
    @filter(() => test == "abc")
    static whatever() {}
}`);
    });

    test("decoratorMetadata - class and method decorator", async () => {
      await expectPass(`
declare var decorator: any;
class Service {}
@decorator
class MyComponent {
    constructor(public Service: Service) {}
    @decorator
    method(x: any) {}
}`);
    });

    test("decoratorMetadataWithTypeOnlyImport", async () => {
      await expectPass(`
declare var decorator: any;
@decorator
class MyComponent {
    constructor(public Service: any) {}
    @decorator
    method(x: any) {}
}`);
    });

    test("decoratorMetadataWithTypeOnlyImport2", async () => {
      await expectPass(`
declare const decorator: any;
class Main {
    @decorator()
    field: any;
}`);
    });
  });

  // ---------------------------------------------------------------------------
  // Error cases (TSC also errors on these)
  // ---------------------------------------------------------------------------
  describe("error cases (TSC also errors)", () => {
    test("decoratorOnClassAccessor3 - modifier before decorator on get", async () => {
      await expectError(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class C {
    public @dec get accessor() { return 1; }
}`);
    });

    test("decoratorOnClassAccessor6 - modifier before decorator on set", async () => {
      await expectError(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class C {
    public @dec set accessor(value: number) { }
}`);
    });

    test("decoratorOnClassConstructorParameter4 - modifier before param decorator", async () => {
      await expectError(`
declare function dec(target: Function, propertyKey: string | symbol, parameterIndex: number): void;

class C {
    constructor(public @dec p: number) {}
}`);
    });

    // decoratorOnClass3: TSC semantic error (type check) — 우리는 타입체크 안 하므로 pass
    test("decoratorOnClass3 - export before decorator", async () => {
      await expectPass(`
declare function dec<T>(target: T): T;

export
@dec
class C {
}`);
    });

    test("decoratorOnClass8 - wrong decorator signature on class", async () => {
      await expectError(`
declare function dec(): (target: Function, paramIndex: number) => void;

@dec()
class C {
}`);
    });

    test("decoratorOnClassMethod3 - modifier before decorator on method", async () => {
      await expectError(`
declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

class C {
    public @dec method() {}
}`);
    });

    test("decoratorOnClassMethod12 - super in decorator expression", async () => {
      await expectError(`
namespace M {
    class S {
        decorator(target: Object, key: string): void { }
    }
    class C extends S {
        @(super.decorator)
        method() { }
    }
}`);
    });

    test("decoratorOnClassMethod17 - decorator after property name", async () => {
      await expectError(`
declare var decorator: any;

class Foo {
    private prop @decorator
    foo() {
        return 0;
    }
}`);
    });

    test("decoratorOnClassMethodParameter3 - await in decorator param", async () => {
      await expectError(`
declare function dec(a: any): any;
function fn(value: Promise<number>): any {
  class Class {
    async method(@dec(await value) arg: number) {}
  }
  return Class
}`);
    });

    test("decoratorOnClassMethodThisParameter - decorator on this param", async () => {
      await expectError(`
declare function dec(target: Object, propertyKey: string | symbol, parameterIndex: number): void;

class C {
    method(@dec this: C) {}
}

class C2 {
    method(@dec allowed: C2, @dec this: C2) {}
}`);
    });

    test("decoratorOnClassProperty3 - modifier before decorator on property", async () => {
      await expectError(`
declare function dec(target: any, propertyKey: string): void;

class C {
    public @dec prop;
}`);
    });

    test("decoratorMetadata-jsdoc - JSDoc syntax errors", async () => {
      await expectError(`
declare var decorator: any;

class X {
    @decorator()
    a?: string?;
    @decorator()
    b?: string!;
    @decorator()
    c?: *;
}`);
    });
  });
});
