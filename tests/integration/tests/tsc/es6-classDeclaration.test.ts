import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: es6/classDeclaration", () => {
  test("classWithSemicolonClassElementES61", async () => {
    await expectPass(
      `class C {
    ;
}`,
      [],
    );
  });
  test("classWithSemicolonClassElementES62", async () => {
    await expectPass(
      `class C {
    ;
    ;
}`,
      [],
    );
  });
  test("emitClassDeclarationOverloadInES6", async () => {
    await expectPass(
      `// @target: es6
class C {
    constructor(y: any)
    constructor(x: number) {
    }
}

class D {
    constructor(y: any)
    constructor(x: number, z="hello") {}
}`,
      [],
    );
  });
  test("emitClassDeclarationWithConstructorInES6", async () => {
    await expectPass(
      `// @strict: false
class A {
    y: number;
    constructor(x: number) {
    }
    foo(a: any);
    foo() { }
}

class B {
    y: number;
    x: string = "hello";
    _bar: string;

    constructor(x: number, z = "hello", ...args) {
        this.y = 10;
    }
    baz(...args): string;
    baz(z: string, v: number): string {
        return this._bar;
    } 
}


`,
      [],
    );
  });
  test("emitClassDeclarationWithExtensionAndTypeArgumentInES6", async () => {
    await expectPass(
      `// @target: es6
class B<T> {
    constructor(a: T) { }
}
class C extends B<string> { }
class D extends B<number> {
    constructor(a: any)
    constructor(b: number) {
        super(b);
    }
}`,
      [],
    );
  });
  test("emitClassDeclarationWithExtensionInES6", async () => {
    await expectPass(
      `// @target: es6
class B {
    baz(a: string, y = 10) { }
}
class C extends B {
    foo() { }
    baz(a: string, y:number) {
        super.baz(a, y);
    }
}
class D extends C {
    constructor() {
        super();
    }

    foo() {
        super.foo();
    }

    baz() {
        super.baz("hello", 10);
    }
}
`,
      [],
    );
  });
  test("emitClassDeclarationWithGetterSetterInES6", async () => {
    await expectPass(
      `// @target:es6
class C {
    _name: string;
    get name(): string {
        return this._name;
    }
    static get name2(): string {
        return "BYE";
    }
    static get ["computedname"]() {
        return "";
    }
    get ["computedname1"]() {
        return "";
    }
    get ["computedname2"]() {
        return "";
    }

    set ["computedname3"](x: any) {
    }
    set ["computedname4"](y: string) {
    }

    set foo(a: string) { }
    static set bar(b: number) { }
    static set ["computedname"](b: string) { }
}`,
      [],
    );
  });
  test("emitClassDeclarationWithLiteralPropertyNameInES6", async () => {
    await expectPass(
      `// @target: es6
class B {
    "hello" = 10;
    0b110 = "world";
    0o23534 = "WORLD";
    20 = "twenty";
    "foo"() { }
    0b1110() {}
    11() { }
    interface() { }
    static "hi" = 10000;
    static 22 = "twenty-two";
    static 0b101 = "binary";
    static 0o3235 = "octal";
}`,
      [],
    );
  });
  test("emitClassDeclarationWithMethodInES6", async () => {
    await expectPass(
      `// @target:es6
class D {
    _bar: string;
    foo() { }
    ["computedName1"]() { }
    ["computedName2"](a: string) { }
    ["computedName3"](a: string): number { return 1; }
    bar(): string {
        return this._bar;
    } 
    baz(a: any, x: string): string {
        return "HELLO";
    }
    static ["computedname4"]() { }
    static ["computedname5"](a: string) { }
    static ["computedname6"](a: string): boolean { return true; }
    static staticMethod() {
        var x = 1 + 2;
        return x
    }
    static foo(a: string) { }
    static bar(a: string): number { return 1; }
}`,
      [],
    );
  });
  test("emitClassDeclarationWithPropertyAccessInHeritageClause1", async () => {
    await expectPass(
      `class B {}
function foo() {
    return {B: B};
}
class C extends (foo()).B {}`,
      [],
    );
  });
  test("emitClassDeclarationWithPropertyAssignmentInES6", async () => {
    await expectPass(
      `// @target:es6
class C {
    x: string = "Hello world";
}

class D {
    x: string = "Hello world";
    y: number;
    constructor() {
        this.y = 10;
    }
}

class E extends D{
    z: boolean = true;
}

class F extends D{
    z: boolean = true;
    j: string;
    constructor() {
        super();
        this.j = "HI";
    }
}`,
      [],
    );
  });
  test("emitClassDeclarationWithStaticPropertyAssignmentInES6", async () => {
    await expectPass(
      `// @target:es6
class C {
    static z: string = "Foo";
}

class D {
    x = 20000;
    static b = true;
}
`,
      [],
    );
  });
  test("emitClassDeclarationWithSuperMethodCall01", async () => {
    await expectPass(
      `//@target: es6

class Parent {
    foo() {
    }
}

class Foo extends Parent {
    foo() {
        var x = () => super.foo();
    }
}`,
      [],
    );
  });
  test("emitClassDeclarationWithThisKeywordInES6", async () => {
    await expectPass(
      `// @target: es6
class B {
    x = 10;
    constructor() {
        this.x = 10;
    }
    static log(a: number) { }
    foo() {
        B.log(this.x);
    }

    get X() {
        return this.x;
    }

    set bX(y: number) {
        this.x = y;
    }
}`,
      [],
    );
  });
  test("emitClassDeclarationWithTypeArgumentAndOverloadInES6", async () => {
    await expectPass(
      `// @strict: false
class B<T> {
    x: T;
    B: T;

    constructor(a: any)
    constructor(a: any,b: T)
    constructor(a: T) { this.B = a;}

    foo(a: T)
    foo(a: any)
    foo(b: string)
    foo(): T {
        return this.x;
    }

    get BB(): T {
        return this.B;
    }
    set BBWith(c: T) {
        this.B = c;
    }
}`,
      [],
    );
  });
  test("emitClassDeclarationWithTypeArgumentInES6", async () => {
    await expectPass(
      `// @target: es6
class B<T> {
    x: T;
    B: T;
    constructor(a: T) { this.B = a;}
    foo(): T {
        return this.x;
    }
    get BB(): T {
        return this.B;
    }
    set BBWith(c: T) {
        this.B = c;
    }
}`,
      [],
    );
  });
  test("exportDefaultClassWithStaticPropertyAssignmentsInES6", async () => {
    await expectPass(
      `export default class {
    static z: string = "Foo";
}`,
      [],
    );
  });
  test("parseClassDeclarationInStrictModeByDefaultInES6", async () => {
    await expectError(
      `// @target: es6
class C {
    interface = 10;
    public implements() { }
    public foo(arguments: any) { }
    private bar(eval:any) {
        arguments = "hello";
    }
}`,
      [],
    );
  });
  test("superCallBeforeThisAccessing1", async () => {
    await expectPass(
      `// @strict: false
declare var Factory: any

class Base {
    constructor(c) { }
}
class D extends Base {
    private _t;
    constructor() {
        super(i);
        var s = {
            t: this._t
        }
        var i = Factory.create(s);
    }
}
`,
      [],
    );
  });
  test("superCallBeforeThisAccessing2", async () => {
    await expectPass(
      `// @strict: false
class Base {
    constructor(c) { }
}
class D extends Base {
    private _t;
    constructor() {
        super(() => { this._t }); // no error. only check when this is directly accessing in constructor
    }
}
`,
      [],
    );
  });
  test("superCallBeforeThisAccessing3", async () => {
    await expectPass(
      `// @target: es2015
class Base {
    constructor(c) { }
}
class D extends Base {
    private _t;
    constructor() {
        let x = () => { this._t };
        x();  // no error; we only check super is called before this when the container is a constructor
        this._t;  // error
        super(undefined);
    }
}
`,
      [],
    );
  });
  test("superCallBeforeThisAccessing4", async () => {
    await expectPass(
      `// @target: es2015
class D extends null {
    private _t;
    constructor() {
        this._t;
        super();
    }
}

class E extends null {
    private _t;
    constructor() {
        super();
        this._t;
    }
}`,
      [],
    );
  });
  test("superCallBeforeThisAccessing5", async () => {
    await expectPass(
      `// @strict: false
class D extends null {
    private _t;
    constructor() {
        this._t;  // No error
    }
}
`,
      [],
    );
  });
  test("superCallBeforeThisAccessing6", async () => {
    await expectPass(
      `// @target: es2015
class Base {
    constructor(c) { }
}
class D extends Base {
    private _t;
    constructor() {
        super(this); 
    }
}
`,
      [],
    );
  });
  test("superCallBeforeThisAccessing7", async () => {
    await expectPass(
      `// @target: es2015
class Base {
    constructor(c) { }
}
class D extends Base {
    private _t;
    constructor() {
        let x = {
            j: this._t,
        }
        super(undefined);
    }
}
`,
      [],
    );
  });
  test("superCallBeforeThisAccessing8", async () => {
    await expectPass(
      `// @strict: false
class Base {
    constructor(c) { }
}
class D extends Base {
    private _t;
    constructor() {
        let x = {
            k: super(undefined), 
            j: this._t,  // no error
        }
    }
}
`,
      [],
    );
  });
  test("superCallFromClassThatHasNoBaseTypeButWithSameSymbolInterface", async () => {
    await expectError(
      `interface Foo extends Array<number> {}

class Foo {
    constructor() {
        super(); // error
    }
}`,
      [],
    );
  });
});
