import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: classes", () => {
  test("awaitAndYieldInProperty", async () => {
    await expectError(
      `async function* test(x: Promise<string>) {
    class C {
        [await x] = await x;
        static [await x] = await x;

        [yield 1] = yield 2;
        static [yield 3] = yield 4;
    }

    return class {
        [await x] = await x;
        static [await x] = await x;

        [yield 1] = yield 2;
        static [yield 3] = yield 4;
    }
}`,
      [],
    );
  });
  test("classAbstractAccessor", async () => {
    await expectPass(
      `
abstract class A {
   abstract get a();
   abstract get aa() { return 1; } // error
   abstract set b(x: string);
   abstract set bb(x: string) {} // error
}
`,
      [],
    );
  });
  test("classAbstractAsIdentifier", async () => {
    await expectPass(
      `class abstract {
    foo() { return 1; }
}

new abstract;`,
      [],
    );
  });
  test("classAbstractAssignabilityConstructorFunction", async () => {
    await expectPass(
      `abstract class A { }

// var AA: typeof A;
var AAA: new() => A;

// AA = A; // okay
AAA = A; // error. 
AAA = "asdf";`,
      [],
    );
  });
  test("classAbstractClinterfaceAssignability", async () => {
    await expectPass(
      `interface I {
    x: number;
}

interface IConstructor {
    new (): I;
    
    y: number;
    prototype: I;
}

declare var I: IConstructor;

abstract class A {
    x: number;
    static y: number;
}

declare var AA: typeof A;
AA = I;

declare var AAA: typeof I;
AAA = A;`,
      [],
    );
  });
  test("classAbstractConstructor", async () => {
    await expectPass(
      `abstract class A {
    abstract constructor() {}
}`,
      [],
    );
  });
  test("classAbstractConstructorAssignability", async () => {
    await expectPass(
      `
class A {}

abstract class B extends A {}

class C extends B {}

var AA : typeof A = B;
var BB : typeof B = A;
var CC : typeof C = B;

new AA;
new BB;
new CC;`,
      [],
    );
  });
  test("classAbstractCrashedOnce", async () => {
    await expectError(
      `abstract class foo {
    protected abstract test();
}

class bar extends foo {
    test() {
        this.
    }
}
var x = new bar();`,
      [],
    );
  });
  test("classAbstractDeclarations.d", async () => {
    await expectPass(
      `declare abstract class A {
    abstract constructor() {}
}

declare abstract class AA {
    abstract foo();
}

declare abstract class BB extends AA {}

declare class CC extends AA {}

declare class DD extends BB {}

declare abstract class EE extends BB {}

declare class FF extends CC {}

declare abstract class GG extends CC {}

declare abstract class AAA {}

declare abstract class BBB extends AAA {}

declare class CCC extends AAA {}`,
      [],
    );
  });
  test("classAbstractExtends", async () => {
    await expectPass(
      `
class A {
    foo() {}
}

abstract class B extends A {
    abstract bar();
}

class C extends B { }

abstract class D extends B {}

class E extends B {
    bar() {}
}`,
      [],
    );
  });
  test("classAbstractFactoryFunction", async () => {
    await expectPass(
      `
class A {}
abstract class B extends A {}

function NewA(Factory: typeof A) {
    return new A;
}

function NewB(Factory: typeof B) {
    return new B;
}

NewA(A);
NewA(B);

NewB(A);
NewB(B);`,
      [],
    );
  });
  test("classAbstractGeneric", async () => {
    await expectPass(
      `abstract class A<T> {
    t: T;
    
    abstract foo(): T;
    abstract bar(t: T);
}

abstract class B<T> extends A<T> {}

class C<T> extends A<T> {} // error -- inherits abstract methods

class D extends A<number> {} // error -- inherits abstract methods

class E<T> extends A<T> { // error -- doesn't implement bar
    foo() { return this.t; }
}

class F<T> extends A<T> { // error -- doesn't implement foo
    bar(t : T) {}
}

class G<T> extends A<T> {
    foo() { return this.t; }
    bar(t: T) { }
}`,
      [],
    );
  });
  test("classAbstractInAModule", async () => {
    await expectPass(
      `namespace M {
    export abstract class A {}
    export class B extends A {}
}

new M.A;
new M.B;`,
      [],
    );
  });
  test("classAbstractInheritance1", async () => {
    await expectPass(
      `abstract class A {}

abstract class B extends A {}

class C extends A {}

abstract class AA {
    abstract foo();
}

abstract class BB extends AA {}

class CC extends AA {}

class DD extends BB {}

abstract class EE extends BB {}

class FF extends CC {}

abstract class GG extends CC {}`,
      [],
    );
  });
  test("classAbstractInheritance2", async () => {
    await expectPass(
      `abstract class A {
    abstract m1(): number;
    abstract m2(): number;
    abstract m3(): number;
    abstract m4(): number;
    abstract m5(): number;
    abstract m6(): number;
}

class B extends A { }
const C = class extends A {}
`,
      [],
    );
  });
  test("classAbstractInstantiations1", async () => {
    await expectPass(
      `
//
// Calling new with (non)abstract classes.
//

abstract class A {}

class B extends A {}

abstract class C extends B {}

new A;
new A(1); // should report 1 error
new B;
new C;

var a : A;
var b : B;
var c : C;

a = new B;
b = new B;
c = new B;
`,
      [],
    );
  });
  test("classAbstractInstantiations2", async () => {
    await expectPass(
      `class A {
    // ...
}

abstract class B {
    foo(): number { return this.bar(); }
    abstract bar() : number;
}

new B; // error

var BB: typeof B = B;
var AA: typeof A = BB; // error, AA is not of abstract type.
new AA;

function constructB(Factory : typeof B) {
    new Factory; // error -- Factory is of type typeof B.
}

var BB = B;
new BB; // error -- BB is of type typeof B.

var x : any = C;
new x; // okay -- undefined behavior at runtime

class C extends B { } // error -- not declared abstract

abstract class D extends B { } // okay

class E extends B { // okay -- implements abstract method
    bar() { return 1; }
}

abstract class F extends B {
    abstract foo() : number;
    bar() { return 2; }
}

abstract class G {
    abstract qux(x : number) : string;
    abstract qux() : number;
    y : number;
    abstract quz(x : number, y : string) : boolean; // error -- declarations must be adjacent

    abstract nom(): boolean;
    nom(x : number): boolean; // error -- use of modifier abstract must match on all overloads.
}

class H { // error -- not declared abstract
    abstract baz() : number;
}`,
      [],
    );
  });
  test("classAbstractMergedDeclaration", async () => {
    await expectPass(
      `abstract class CM {}
namespace CM {}

namespace MC {}
abstract class MC {}

abstract class CI {}
interface CI {}

interface IC {}
abstract class IC {}

abstract class CC1 {}
class CC1 {}

class CC2 {}
abstract class CC2 {}

declare abstract class DCI {}
interface DCI {}

interface DIC {}
declare abstract class DIC {}

declare abstract class DCC1 {}
declare class DCC1 {}

declare class DCC2 {}
declare abstract class DCC2 {}

new CM;
new MC;
new CI;
new IC;
new CC1;
new CC2;
new DCI;
new DIC;
new DCC1;
new DCC2;`,
      [],
    );
  });
  test("classAbstractMethodInNonAbstractClass", async () => {
    await expectPass(
      `class A {
    abstract foo();
}

class B {
    abstract foo() {}
}`,
      [],
    );
  });
  test("classAbstractMethodWithImplementation", async () => {
    await expectPass(
      `abstract class A {
    abstract foo() {}
}`,
      [],
    );
  });
  test("classAbstractMixedWithModifiers", async () => {
    await expectError(
      `abstract class A {
    abstract foo_a();

    public abstract foo_b();
    protected abstract foo_c();
    private abstract foo_d();

    abstract public foo_bb();
    abstract protected foo_cc();
    abstract private foo_dd();

    abstract static foo_d();
    static abstract foo_e();

    abstract async foo_f();
    async abstract foo_g();
}
`,
      [],
    );
  });
  test("classAbstractOverloads", async () => {
    await expectPass(
      `abstract class A {
    abstract foo();
    abstract foo() : number;
    abstract foo();
    
    abstract bar();
    bar();
    abstract bar();
    
    abstract baz();
    baz();
    abstract baz();
    baz() {}
    
    qux();
}

abstract class B {
    abstract foo() : number;
    abstract foo();
    x : number;
    abstract foo();
    abstract foo();
}`,
      [],
    );
  });
  test("classAbstractOverrideWithAbstract", async () => {
    await expectPass(
      `class A {
    foo() {}
}

abstract class B extends A {
    abstract foo();
}

abstract class AA {
    foo() {}
    abstract bar();
}

abstract class BB extends AA {
    abstract foo();
    bar () {}
}

class CC extends BB {} // error

class DD extends BB {
    foo() {}
}`,
      [],
    );
  });
  test("classAbstractProperties", async () => {
    await expectPass(
      `abstract class A {
    abstract x : number;
    public abstract y : number;
    protected abstract z : number;
    private abstract w : number;
    
    abstract m: () => void; 
    
    abstract foo_x() : number;
    public abstract foo_y() : number;
    protected abstract foo_z() : number;
    private abstract foo_w() : number;
}`,
      [],
    );
  });
  test("classAbstractSingleLineDecl", async () => {
    await expectPass(
      `abstract class A {}

abstract
class B {}

abstract

class C {}

new A;
new B;
new C;`,
      [],
    );
  });
  test("classAbstractSuperCalls", async () => {
    await expectPass(
      `
class A {
    foo() { return 1; }
}

abstract class B extends A {
    abstract foo();
    bar() { super.foo(); }
    baz() { return this.foo; }
}

class C extends B {
    foo() { return 2; }
    qux() { return super.foo() || super.foo; } // 2 errors, foo is abstract
    norf() { return super.bar(); }
}

class AA {
    foo() { return 1; }
    bar() { return this.foo(); }
}

abstract class BB extends AA {
    abstract foo();
    // inherits bar. But BB is abstract, so this is OK.
}
`,
      [],
    );
  });
  test("classAbstractUsingAbstractMethod1", async () => {
    await expectPass(
      `abstract class A {
    abstract foo() : number;
}

class B extends A {
    foo() { return 1; }
}

abstract class C extends A  {
    abstract foo() : number;
}

var a = new B;
a.foo();

a = new C; // error, cannot instantiate abstract class.
a.foo();`,
      [],
    );
  });
  test("classAbstractUsingAbstractMethods2", async () => {
    await expectPass(
      `class A {
    abstract foo();
}

class B extends A  {}

abstract class C extends A {}

class D extends A {
    foo() {}
}

abstract class E extends A {
    foo() {}
}

abstract class AA {
    abstract foo();
}

class BB extends AA  {}

abstract class CC extends AA {}

class DD extends AA {
    foo() {}
}`,
      [],
    );
  });
  test("classAbstractWithInterface", async () => {
    await expectError(`abstract interface I {}`, []);
  });
  test("classAndInterfaceMerge.d", async () => {
    await expectPass(
      `
interface C { }

declare class C { }

interface C { }

interface C { }

declare namespace M {

    interface C1 { }

    class C1 { }

    interface C1 { }

    interface C1 { }

    export class C2 { }
}

declare namespace M {
    export interface C2 { }
}`,
      [],
    );
  });
  test("classAndInterfaceMergeConflictingMembers", async () => {
    await expectPass(
      `declare class C1 {
    public x : number;
}

interface C1 {
    x : number;
}

declare class C2 {
    protected x : number;
}

interface C2 {
    x : number;
}

declare class C3 {
    private x : number;
}

interface C3 {
    x : number;
}`,
      [],
    );
  });
  test("classAndInterfaceWithSameName", async () => {
    await expectPass(
      `class C { foo: string; }
interface C { foo: string; }

namespace M {
    class D {
        bar: string;
    }

    interface D {
        bar: string;
    }
}`,
      [],
    );
  });
  test("classAndVariableWithSameName", async () => {
    await expectPass(
      `class C { foo: string; } // error
var C = ''; // error

namespace M {
    class D { // error
        bar: string;
    }

    var D = 1; // error
}`,
      [],
    );
  });
  test("classBodyWithStatements", async () => {
    await expectError(
      `class C {
    var x = 1;
}

class C2 {
    function foo() {}
}

var x = 1;
var y = 2;
class C3 {
    x: number = y + 1; // ok, need a var in the statement production
}`,
      [],
    );
  });
  test("classWithEmptyBody", async () => {
    await expectPass(
      `class C {
}

var c: C;
var o: {} = c;
c = 1;
c = { foo: '' }
c = () => { }

class D {
    constructor() {
        return 1;
    }
}

var d: D;
var o: {} = d;
d = 1;
d = { foo: '' }
d = () => { }`,
      [],
    );
  });
  test("classDeclarationLoop", async () => {
    await expectPass(
      `const arr = [];
for (let i = 0; i < 10; ++i) {
    class C {
        prop = i;
    }
    arr.push(C);
}`,
      [],
    );
  });
  test("classExtendingBuiltinType", async () => {
    await expectPass(
      `class C1 extends Object { }
class C2 extends Function { }
class C3 extends String { }
class C4 extends Boolean { }
class C5 extends Number { }
class C6 extends Date { }
class C7 extends RegExp { }
class C8 extends Error { }
class C9 extends Array { }
class C10 extends Array<number> { }
`,
      [],
    );
  });
  test("classExtendingClassLikeType", async () => {
    await expectPass(
      `interface Base<T, U> {
    x: T;
    y: U;
}

// Error, no Base constructor function
class D0 extends Base<string, string> {
}

interface BaseConstructor {
    new (x: string, y: string): Base<string, string>;
    new <T>(x: T): Base<T, T>;
    new <T>(x: T, y: T): Base<T, T>;
    new <T, U>(x: T, y: U): Base<T, U>;
}

declare function getBase(): BaseConstructor;

class D1 extends getBase() {
    constructor() {
        super("abc", "def");
        this.x = "x";
        this.y = "y";
    }
}

class D2 extends getBase() <number> {
    constructor() {
        super(10);
        super(10, 20);
        this.x = 1;
        this.y = 2;
    }
}

class D3 extends getBase() <string, number> {
    constructor() {
        super("abc", 42);
        this.x = "x";
        this.y = 2;
    }
}

// Error, no constructors with three type arguments
class D4 extends getBase() <string, string, string> {
}

interface BadBaseConstructor {
    new (x: string): Base<string, string>;
    new (x: number): Base<number, number>;
}

declare function getBadBase(): BadBaseConstructor;

// Error, constructor return types differ
class D5 extends getBadBase() {
}
`,
      [],
    );
  });
  test("classExtendingNonConstructor", async () => {
    await expectPass(
      `var x: {};

function foo() {
    this.x = 1;
}

class C1 extends undefined { }
class C2 extends true { }
class C3 extends false { }
class C4 extends 42 { }
class C5 extends "hello" { }
class C6 extends x { }
class C7 extends foo { }
`,
      [],
    );
  });
  test("classExtendingNull", async () => {
    await expectPass(
      `class C1 extends null { }
class C2 extends (null) { }
class C3 extends null { x = 1; }
class C4 extends (null) { x = 1; }`,
      [],
    );
  });
  test("classAppearsToHaveMembersOfObject", async () => {
    await expectPass(
      `class C { foo: string; }

var c: C;
var r = c.toString();
var r2 = c.hasOwnProperty('');
var o: Object = c;
var o2: {} = c;
`,
      [],
    );
  });
  test("classExtendingClass", async () => {
    await expectPass(
      `class C {
    foo: string;
    thing() { }
    static other() { }
}

class D extends C {
    bar: string;
}

var d: D;
var r = d.foo;
var r2 = d.bar;
var r3 = d.thing();
var r4 = D.other();

class C2<T> {
    foo: T;
    thing(x: T) { }
    static other<T>(x: T) { }
}

class D2<T> extends C2<T> {
    bar: string;
}

var d2: D2<string>;
var r5 = d2.foo;
var r6 = d2.bar;
var r7 = d2.thing('');
var r8 = D2.other(1);`,
      [],
    );
  });
  test("classExtendingOptionalChain", async () => {
    await expectError(
      `namespace A {
    export class B {}
}

// ok
class C1 extends A?.B {}

// error
class C2 implements A?.B {}
`,
      [],
    );
  });
  test("classExtendingPrimitive", async () => {
    await expectError(
      `// classes cannot extend primitives

class C extends number { }
class C2 extends string { }
class C3 extends boolean { }
class C4 extends Void  { }
class C4a extends void {}
class C5 extends Null { }
class C5a extends null { }
class C6 extends undefined { }
class C7 extends Undefined { }

enum E { A }
class C8 extends E { }

const C9 = class extends number { }
const C10 = class extends string { }
const C11 = class extends boolean { }

const C12 = class A extends number { }
const C13 = class B extends string { }
const C14 = class C extends boolean { }
`,
      [],
    );
  });
  test("classExtendingPrimitive2", async () => {
    await expectError(
      `// classes cannot extend primitives

class C4a extends void {}
class C5a extends null { }`,
      [],
    );
  });
  test("classExtendsEveryObjectType", async () => {
    await expectError(
      `interface I {
    foo: string;
}
class C extends I { } // error

class C2 extends { foo: string; } { } // error
declare var x: { foo: string; }
class C3 extends x { } // error

namespace M { export var x = 1; }
class C4 extends M { } // error

function foo() { }
class C5 extends foo { } // error

class C6 extends []{ } // error`,
      [],
    );
  });
  test("classExtendsEveryObjectType2", async () => {
    await expectError(
      `class C2 extends { foo: string; } { } // error

class C6 extends []{ } // error`,
      [],
    );
  });
  test("classExtendsItself", async () => {
    await expectPass(
      `class C extends C { } // error

class D<T> extends D<T> { } // error

class E<T> extends E<string> { } // error`,
      [],
    );
  });
  test("classExtendsItselfIndirectly", async () => {
    await expectPass(
      `class C extends E { foo: string; } // error

class D extends C { bar: string; }

class E extends D { baz: number; }

class C2<T> extends E2<T> { foo: T; } // error

class D2<T> extends C2<T> { bar: T; }

class E2<T> extends D2<T> { baz: T; }`,
      [],
    );
  });
  test("classExtendsItselfIndirectly2", async () => {
    await expectPass(
      `class C extends N.E { foo: string; } // error

namespace M {
    export class D extends C { bar: string; }

}

namespace N {
    export class E extends M.D { baz: number; }
}

namespace O {
    class C2<T> extends Q.E2<T> { foo: T; } // error

    namespace P {
        export class D2<T> extends C2<T> { bar: T; }
    }

    namespace Q {
        export class E2<T> extends P.D2<T> { baz: T; }
    }
}`,
      [],
    );
  });
  test("classExtendsItselfIndirectly3", async () => {
    await expectPass(
      `class C extends E { foo: string; } // error

class D extends C { bar: string; }

class E extends D { baz: number; }

class C2<T> extends E2<T> { foo: T; } // error

class D2<T> extends C2<T> { bar: T; }

class E2<T> extends D2<T> { baz: T; }`,
      [],
    );
  });
  test("classExtendsShadowedConstructorFunction", async () => {
    await expectPass(
      `class C { foo: string; }

namespace M {
    var C = 1;
    class D extends C { // error, C must evaluate to constructor function
        bar: string;
    }
}`,
      [],
    );
  });
  test("classExtendsValidConstructorFunction", async () => {
    await expectPass(
      `function foo() { }

var x = new foo(); // can be used as a constructor function

class C extends foo { } // error, cannot extend it though`,
      [],
    );
  });
  test("classIsSubtypeOfBaseType", async () => {
    await expectPass(
      `class Base<T> {
    foo: T;
}

class Derived extends Base<{ bar: string; }> {
    foo: {
        bar: string; baz: number; // ok
    }
}

class Derived2 extends Base<{ bar: string; }> {
    foo: {
        bar?: string; // error
    }
}`,
      [],
    );
  });
  test("constructorFunctionTypeIsAssignableToBaseType", async () => {
    await expectPass(
      `class Base {
    static foo: {
        bar: Object;
    }
}

class Derived extends Base {
    // ok
    static foo: {
        bar: number;
    }
}

class Derived2 extends Base {
    // ok, use assignability here
    static foo: {
        bar: any;
    }
}`,
      [],
    );
  });
  test("constructorFunctionTypeIsAssignableToBaseType2", async () => {
    await expectPass(
      `// the constructor function itself does not need to be a subtype of the base type constructor function

class Base {
    static foo: {
        bar: Object;
    }
    constructor(x: Object) {
    }
}

class Derived extends Base {
    // ok
    static foo: {
        bar: number;
    }

    constructor(x: number) {
        super(x);
    }
}

class Derived2 extends Base {   
    static foo: {
        bar: number;
    }

    // ok, not enforcing assignability relation on this
    constructor(x: any) {
        super(x);
        return 1;
    }
}`,
      [],
    );
  });
  test("derivedTypeDoesNotRequireExtendsClause", async () => {
    await expectPass(
      `class Base {
    foo: string;
}

class Derived {
    foo: string;
    bar: number;
}

class Derived2 extends Base {
    bar: string;
}

var b: Base;
var d1: Derived;
var d2: Derived2;
b = d1;
b = d2;

var r: Base[] = [d1, d2];`,
      [],
    );
  });
  test("classImplementsMergedClassInterface", async () => {
    await expectPass(
      `declare class C1 {
    x : number;
}

interface C1 {
    y : number;
}

class C2 implements C1 { // error -- missing x
}

class C3 implements C1 { // error -- missing y
    x : number;
}

class C4 implements C1 { // error -- missing x
    y : number;
}

class C5 implements C1 { // okay
    x : number;
    y : number;
}`,
      [],
    );
  });
  test("classInsideBlock", async () => {
    await expectPass(
      `function foo() {
    class C { }
}`,
      [],
    );
  });
  test("classWithPredefinedTypesAsNames", async () => {
    await expectPass(
      `// classes cannot use predefined types as names

class any { }
class number { }
class boolean { }
class string { }`,
      [],
    );
  });
  test("classWithPredefinedTypesAsNames2", async () => {
    await expectError(
      `// classes cannot use predefined types as names

class void {}`,
      [],
    );
  });
  test("classWithSemicolonClassElement1", async () => {
    await expectPass(
      `class C {
    ;
}`,
      [],
    );
  });
  test("classWithSemicolonClassElement2", async () => {
    await expectPass(
      `class C {
    ;
    ;
}`,
      [],
    );
  });
  test("declaredClassMergedwithSelf", async () => {
    await expectPass(
      `

declare class C1 {}

declare class C1 {}

declare class C2 {}

interface C2 {}

declare class C2 {}


declare class C3 { }


declare class C3 { }`,
      [],
    );
  });
  test("mergeClassInterfaceAndModule", async () => {
    await expectPass(
      `
interface C1 {}
declare class C1 {}
namespace C1 {}

declare class C2 {}
interface C2 {}
namespace C2 {}

declare class C3 {}
namespace C3 {}
interface C3 {}

namespace C4 {}
declare class C4 {} // error -- class declaration must precede module declaration
interface C4 {}`,
      [],
    );
  });
  test("mergedClassInterface", async () => {
    await expectPass(
      `

declare class C1 { }

interface C1 { }

interface C2 { }

declare class C2 { }

class C3 { }

interface C3 { }

interface C4 { }

class C4 { }

interface C5 {
    x1: number;
}

declare class C5 {
    x2: number;
}

interface C5 {
    x3: number;
}

interface C5 {
    x4: number;
}

// checks if properties actually were merged
var c5 : C5;
c5.x1;
c5.x2;
c5.x3;
c5.x4;


declare class C6 { }

interface C7 { }


interface C6 { }

declare class C7 { }`,
      [],
    );
  });
  test("mergedInheritedClassInterface", async () => {
    await expectPass(
      `interface BaseInterface {
    required: number;
    optional?: number;
}

class BaseClass {
    baseMethod() { }
    baseNumber: number;
}

interface Child extends BaseInterface {
    additional: number;
}

class Child extends BaseClass {
    classNumber: number;
    method() { }
}

interface ChildNoBaseClass extends BaseInterface {
    additional2: string;
}
class ChildNoBaseClass {
    classString: string;
    method2() { }
}
class Grandchild extends ChildNoBaseClass {
}

// checks if properties actually were merged
var child : Child;
child.required;
child.optional;
child.additional;
child.baseNumber;
child.classNumber;
child.baseMethod();
child.method();

var grandchild: Grandchild;
grandchild.required;
grandchild.optional;
grandchild.additional2;
grandchild.classString;
grandchild.method2();
`,
      [],
    );
  });
  test("modifierOnClassDeclarationMemberInFunction", async () => {
    await expectPass(
      `// @target: es2015

function f() {
    class C {
        public baz = 1;
        static foo() { }
        public bar() { }
    }
}`,
      [],
    );
  });
  test("classExpression", async () => {
    await expectPass(
      `var x = class C {
}

var y = {
    foo: class C2 {
    }
}

namespace M {
    var z = class C4 {
    }
}`,
      [],
    );
  });
  test("classExpression1", async () => {
    await expectPass(`var v = class C {};`, []);
  });
  test("classExpression2", async () => {
    await expectPass(
      `class D { }
var v = class C extends D {};`,
      [],
    );
  });
  test("classExpression3", async () => {
    await expectPass(
      `let C = class extends class extends class { a = 1 } { b = 2 } { c = 3 };
let c = new C();
c.a;
c.b;
c.c;
`,
      [],
    );
  });
  test("classExpression4", async () => {
    await expectPass(
      `let C = class {
    foo() {
        return new C();
    }
};
let x = (new C).foo();
`,
      [],
    );
  });
  test("classExpression5", async () => {
    await expectPass(
      `new class {
    hi() {
        return "Hi!";
    }
}().hi();`,
      [],
    );
  });
  test("classExpressionLoop", async () => {
    await expectPass(
      `let arr = [];
for (let i = 0; i < 10; ++i) {
    arr.push(class C {
        prop = i;
    });
}`,
      [],
    );
  });
  test("classWithStaticFieldInParameterBindingPattern.2", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/36295
class C {}
(({ [class extends C { static x = 1 }.x]: b = "" }) => { var C; })();

const x = "";
(({ [class extends C { static x = 1 }.x]: b = "" }, d = x) => { var x; })();
`,
      [],
    );
  });
  test("classWithStaticFieldInParameterBindingPattern.3", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/36295
class C {}
(({ [class extends C { static x = 1 }.x]: b = "" }) => { var C; })();

const x = "";
(({ [class extends C { static x = 1 }.x]: b = "" }, d = x) => { var x; })();
`,
      [],
    );
  });
  test("classWithStaticFieldInParameterBindingPattern", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/36295
(({ [class { static x = 1 }.x]: b = "" }) => {})();`,
      [],
    );
  });
  test("classWithStaticFieldInParameterInitializer.2", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/36295
class C {}
((b = class extends C { static x = 1 }) => { var C; })();

const x = "";
((b = class extends C { static x = 1 }, d = x) => { var x; })();`,
      [],
    );
  });
  test("classWithStaticFieldInParameterInitializer.3", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/36295
class C {}
((b = class extends C { static x = 1 }) => { var C; })();

const x = "";
((b = class extends C { static x = 1 }, d = x) => { var x; })();`,
      [],
    );
  });
  test("classWithStaticFieldInParameterInitializer", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/36295
((b = class { static x = 1 }) => {})();`,
      [],
    );
  });
  test("genericClassExpressionInFunction", async () => {
    await expectPass(
      `// @target: es2015
class A<T> {
    genericVar: T
}
function B1<U>() {
    // class expression can use T
    return class extends A<U> { }
}
class B2<V> {
    anon = class extends A<V> { }
}
function B3<W>() {
    return class Inner<TInner> extends A<W> { }
}
// extends can call B
class K extends B1<number>() {
    namae: string;
}
class C extends (new B2<number>().anon) {
    name: string;
}
let b3Number = B3<number>();
class S extends b3Number<string> {
    nom: string;
}
var c = new C();
var k = new K();
var s = new S();
c.genericVar = 12;
k.genericVar = 12;
s.genericVar = 12;
`,
      [],
    );
  });
  test("modifierOnClassExpressionMemberInFunction", async () => {
    await expectPass(
      `// @target: es2015

function g() {
    var x = class C {
        public prop1 = 1;
        private foo() { }
        static prop2 = 43;
    }
}`,
      [],
    );
  });
  test("classStaticBlock1", async () => {
    await expectPass(
      `const a = 2;

class C {
    static {
        const a = 1;

        a;
    }
}
`,
      [],
    );
  });
  test("classStaticBlock10", async () => {
    await expectPass(
      `var a1 = 1;
var a2 = 1;
const b1 = 2;
const b2 = 2;

function f () {
    var a1 = 11;
    const b1 = 22;

    class C1 {
        static {
            var a1 = 111;
            var a2 = 111;
            const b1 = 222;
            const b2 = 222;
        }
    }
}

class C2 {
    static {
        var a1 = 111;
        var a2 = 111;
        const b1 = 222;
        const b2 = 222;
    }
}
`,
      [],
    );
  });
  test("classStaticBlock11", async () => {
    await expectPass(
      `
let getX;
class C {
  #x = 1
  constructor(x: number) {
    this.#x = x;
  }

  static {
    // getX has privileged access to #x
    getX = (obj: C) => obj.#x;
  }
}
`,
      [],
    );
  });
  test("classStaticBlock12", async () => {
    await expectPass(
      `
class C {
  static #x = 1;
  
  static {
    C.#x;
  }
}
`,
      [],
    );
  });
  test("classStaticBlock13", async () => {
    await expectPass(
      `
class C {
  static #x = 123;

  static {
    console.log(C.#x)
  }

  foo () {
    return C.#x;
  }
}
`,
      [],
    );
  });
  test("classStaticBlock14", async () => {
    await expectPass(
      `
class C {
  static #_1 = 1;
  static #_3 = 1;
  static #_5 = 1;

  static {}
  static {}
  static {}
  static {}
  static {}
  static {}
}
`,
      [],
    );
  });
  test("classStaticBlock15", async () => {
    await expectPass(
      `var _C__1;

class C {
  static #_1 = 1;
  static #_3 = 3;
  static #_5 = 5;

  static {}
  static {}
  static {}
  static {}
  static {}
  static {}
}

console.log(_C__1)
`,
      [],
    );
  });
  test("classStaticBlock16", async () => {
    await expectPass(
      `
let getX: (c: C) => number;
class C {
  #x = 1
  constructor(x: number) {
    this.#x = x;
  }

  static {
    // getX has privileged access to #x
    getX = (obj: C) => obj.#x;
    getY = (obj: D) => obj.#y;
  }
}

let getY: (c: D) => number;
class D {
  #y = 1

  static {
    // getY has privileged access to y
    getX = (obj: C) => obj.#x;
    getY = (obj: D) => obj.#y;
  }
}`,
      [],
    );
  });
  test("classStaticBlock17", async () => {
    await expectPass(
      `
let friendA: { getX(o: A): number, setX(o: A, v: number): void };

class A {
  #x: number;

  constructor (v: number) {
    this.#x = v;
  }

  getX () {
    return this.#x;
  }

  static {
    friendA = {
      getX(obj) { return obj.#x },
      setX(obj, value) { obj.#x = value }
    };
  }
};

class B {
  constructor(a: A) {
    const x = friendA.getX(a); // ok
    friendA.setX(a, x + 1); // ok
  }
};

const a = new A(41);
const b = new B(a);
a.getX();`,
      [],
    );
  });
  test("classStaticBlock18", async () => {
    await expectPass(
      `
function foo () {
  return class {
    static foo = 1;
    static {
      const c = class {
        static bar = 2;
        static {
          // do
        }
      }
    }
  }
}
`,
      [],
    );
  });
  test("classStaticBlock19", async () => {
    await expectPass(
      `class C {
    @decorator
    static {
        // something
    }
}
`,
      [],
    );
  });
  test("classStaticBlock2", async () => {
    await expectPass(
      `
const a = 1;
const b = 2;

class C {
    static {
        const a = 11;

        a;
        b;
    }

    static {
        const a = 11;

        a;
        b;
    }
}
`,
      [],
    );
  });
  test("classStaticBlock20", async () => {
    await expectError(
      `class C {
    async static {
        // something
    }

    public static {
        // something
    }

    readonly private static {
        // something
    }
}
`,
      [],
    );
  });
  test("classStaticBlock21", async () => {
    await expectPass(
      `class C {
    /* jsdocs */
    static {
        // something
    }
}
`,
      [],
    );
  });
  test("classStaticBlock22", async () => {
    await expectError(
      `
let await: "any";
class C {
  static {
    let await: any; // illegal, cannot declare a new binding for await
  }
  static {
    let { await } = {} as any; // illegal, cannot declare a new binding for await
  }
  static {
    let { await: other } = {} as any; // legal
  }
  static {
    let await; // illegal, cannot declare a new binding for await
  }
  static {
    function await() { }; // illegal
  }
  static {
    class await { }; // illegal
  }

  static {
    class D {
      await = 1; // legal
      x = await; // legal (initializers have an implicit function boundary)
    };
  }
  static {
    (function await() { }); // legal, 'await' in function expression name not bound inside of static block
  }
  static {
    (class await { }); // legal, 'await' in class expression name not bound inside of static block
  }
  static {
    (function () { return await; }); // legal, 'await' is inside of a new function boundary
  }
  static {
    (() => await); // legal, 'await' is inside of a new function boundary
  }

  static {
    class E {
      constructor() { await; }
      method() { await; }
      get accessor() {
        await;
        return 1;
      }
      set accessor(v: any) {
        await;
      }
      propLambda = () => { await; }
      propFunc = function () { await; }
    }
  }
  static {
    class S {
      static method() { await; }
      static get accessor() {
        await;
        return 1;
      }
      static set accessor(v: any) {
        await;
      }
      static propLambda = () => { await; }
      static propFunc = function () { await; }
    }
  }
}
`,
      [],
    );
  });
  test("classStaticBlock23", async () => {
    await expectPass(
      `
const nums = [1, 2, 3].map(n => Promise.resolve(n))

class C {
  static {
    for await (const nn of nums) {
        console.log(nn)
    }
  }
}

async function foo () {
  class C {
    static {
      for await (const nn of nums) {
          console.log(nn)
      }
    }
  }
}
`,
      [],
    );
  });
  test("classStaticBlock24", async () => {
    await expectPass(
      `
export class C {
  static x: number;
  static {
    C.x = 1;
  }
}
`,
      [],
    );
  });
  test("classStaticBlock25", async () => {
    await expectPass(
      `
const a = 1;
const b = 2;

class C {
    static {
        const a = 11;

        a;
        b;
    }

    static {
        const a = 11;

        a;
        b;
    }
}
`,
      [],
    );
  });
  test("classStaticBlock26", async () => {
    await expectError(
      `
class C {
    static {
        await; // illegal
    }
    static {
        await (1); // illegal
    }
    static {
        ({ [await]: 1 }); // illegal
    }
    static {
        class D {
            [await] = 1; // illegal (computed property names are evaluated outside of a class body
        };
    }
    static {
        ({ await }); // illegal short-hand property reference
    }
    static {
        await: // illegal, 'await' cannot be used as a label
        break await; // illegal, 'await' cannot be used as a label
    }
    static {
        function f(await) { }
        const ff = (await) => { }
        const fff = await => { }
    }
}
`,
      [],
    );
  });
  test("classStaticBlock27", async () => {
    await expectPass(
      `// https://github.com/microsoft/TypeScript/issues/44872

void class Foo {
    static prop = 1
    static {
        console.log(Foo.prop);
        Foo.prop++;
    }
    static {
        console.log(Foo.prop);
        Foo.prop++;
    }
    static {
        console.log(Foo.prop);
        Foo.prop++;
    }
}`,
      [],
    );
  });
  test("classStaticBlock28", async () => {
    await expectPass(
      `
let foo: number;

class C {
    static {
        foo = 1
    }
}

console.log(foo)`,
      [],
    );
  });
  test("classStaticBlock3", async () => {
    await expectPass(
      `
const a = 1;

class C {
    static f1 = 1;

    static {
        console.log(C.f1, C.f2, C.f3)
    }

    static f2 = 2;

    static {
        console.log(C.f1, C.f2, C.f3)
    }

    static f3 = 3;
}
`,
      [],
    );
  });
  test("classStaticBlock4", async () => {
    await expectPass(
      `
class C {
    static s1 = 1;

    static {
        this.s1;
        C.s1;

        this.s2;
        C.s2;
    }

    static s2 = 2;
    static ss2 = this.s1;
}
`,
      [],
    );
  });
  test("classStaticBlock5", async () => {
    await expectPass(
      `
class B {
    static a = 1;
    static b = 2;
}

class C extends B {
    static b = 3;
    static c = super.a

    static {
        this.b;
        super.b;
        super.a;
    }
}
`,
      [],
    );
  });
  test("classStaticBlock6", async () => {
    await expectError(
      `class B {
    static a = 1;
}

class C extends B {
    static {
        let await = 1;
        let arguments = 1;
        let eval = 1;
    }

    static {
        await: if (true) {

        }

        arguments;
        await;
        super();
    }
}

class CC {
    constructor () {
        class C extends B {
            static {
                class CC extends B {
                    constructor () {
                        super();
                    }
                }
                super();
            }
        }
    }
}

async function foo () {
    class C extends B {
        static {
            arguments;
            await;

            async function ff () {
                arguments;
                await;
            }
        }
    }
}

function foo1 () {
    class C extends B {
        static {
            arguments;

            function ff () {
                arguments;
            }
        }
    }
}

class foo2 {
    static {
        this.b  // should error
        let b: typeof this.b;   // ok
        if (1) {
            this.b; // should error
        }
    }

    static b = 1;
}`,
      [],
    );
  });
  test("classStaticBlock7", async () => {
    await expectError(
      `class C {
    static {
        await 1;
        yield 1;
        return 1;
    }
}

async function f1 () {
    class C {
        static {
            await 1;

            async function ff () {
                await 1;
            }
        }
    }
}

function * f2 () {
    class C {
        static {
            yield 1;

            function * ff () {
                yield 1;
            }
        }
    }
}

function f3 () {
    class C {
        static {
            return 1;

            function ff () {
                return 1
            }
        }
    }
}
`,
      [],
    );
  });
  test("classStaticBlock8", async () => {
    await expectError(
      `function foo (v: number) {
    label: while (v) {
        class C {
            static {
                if (v === 1) {
                    break label;
                }
                if (v === 2) {
                    continue label;
                }
                if (v === 3) {
                    break
                }
                if (v === 4) {
                    continue
                }
            }
        }

        if (v === 5) {
            break label;
        }
        if (v === 6) {
            continue label;
        }
        if (v === 7) {
            break;
        }
        if (v === 8) {
            continue;
        }
    }

    class C {
        static {
            outer: break outer; // valid
            loop: while (v) {
                if (v === 1) break loop; // valid
                if (v === 2) continue loop; // valid
                if (v === 3) break; // valid
                if (v === 4) continue; // valid
            }
            switch (v) {
                default: break; // valid
            }
        }
    }
}
`,
      [],
    );
  });
  test("classStaticBlock9", async () => {
    await expectPass(
      `class A {
    static bar = A.foo + 1
    static {
        A.foo + 2;
    }
    static foo = 1;
}
`,
      [],
    );
  });
  test("classStaticBlockUseBeforeDef1", async () => {
    await expectPass(
      `
class C {
    static x;
    static {
        this.x = 1;
    }
    static y = this.x;
    static z;
    static {
        this.z = this.y;
    }
}
`,
      [],
    );
  });
  test("classStaticBlockUseBeforeDef2", async () => {
    await expectPass(
      `
class C {
    static {
        this.x = 1;
    }
    static x;
}
`,
      [],
    );
  });
  test("classStaticBlockUseBeforeDef3", async () => {
    await expectPass(
      `
class A {
    static {
        A.doSomething(); // should not error
    }

    static doSomething() {
       console.log("gotcha!");
    }
}


class Baz {
    static {
        console.log(FOO);   // should error
    }
}

const FOO = "FOO";
class Bar {
    static {
        console.log(FOO); // should not error
    }
}

let u = "FOO" as "FOO" | "BAR";

class CFA {
    static {
        u = "BAR";
        u;  // should be "BAR"
    }

    static t = 1;

    static doSomething() {}

    static {
        u;  // should be "BAR"
    }
}

u; // should be "BAR"
`,
      [],
    );
  });
  test("classStaticBlockUseBeforeDef4", async () => {
    await expectPass(
      `
class C {
    static accessor x;
    static {
        this.x = 1;
    }
    static accessor y = this.x;
    static accessor z;
    static {
        this.z = this.y;
    }
}`,
      [],
    );
  });
  test("classStaticBlockUseBeforeDef5", async () => {
    await expectPass(
      `
class C {
    static {
        this.x = 1;
    }
    static accessor x;
}`,
      [],
    );
  });
  test("classWithoutExplicitConstructor", async () => {
    await expectPass(
      `class C {
    x = 1
    y = 'hello';
}

var c = new C();
var c2 = new C(null); // error

class D<T extends Date> {
    x = 2
    y: T = null;
}

var d = new D();
var d2 = new D(null); // error`,
      [],
    );
  });
  test("derivedClassWithoutExplicitConstructor", async () => {
    await expectPass(
      `class Base {
    a = 1;
    constructor(x: number) { this.a = x; }
}

class Derived extends Base {
    x = 1
    y = 'hello';
}

var r = new Derived(); // error
var r2 = new Derived(1); 

class Base2<T> {
    a: T;
    constructor(x: T) { this.a = x; }
}

class D<T extends Date> extends Base2<T> {
    x = 2
    y: T = null;
}

var d = new D(); // error
var d2 = new D(new Date()); // ok`,
      [],
    );
  });
  test("derivedClassWithoutExplicitConstructor2", async () => {
    await expectPass(
      `class Base {
    a = 1;
    constructor(x: number, y?: number, z?: number);
    constructor(x: number, y?: number);
    constructor(x: number) { this.a = x; }
}

class Derived extends Base {
    x = 1
    y = 'hello';
}

var r = new Derived(); // error
var r2 = new Derived(1); 
var r3 = new Derived(1, 2);
var r4 = new Derived(1, 2, 3);

class Base2<T> {
    a: T;
    constructor(x: T, y?: T, z?: T);
    constructor(x: T, y?: T);
    constructor(x: T) { this.a = x; }
}

class D<T extends Date> extends Base2<T> {
    x = 2
    y: T = null;
}

var d = new D(); // error
var d2 = new D(new Date()); // ok
var d3 = new D(new Date(), new Date());
var d4 = new D(new Date(), new Date(), new Date());`,
      [],
    );
  });
  test("derivedClassWithoutExplicitConstructor3", async () => {
    await expectPass(
      `// automatic constructors with a class hieararchy of depth > 2

class Base {
    a = 1;
    constructor(x: number) { this.a = x; }
}

class Derived extends Base {
    b = '';
    constructor(y: string, z: string) {
        super(2);
        this.b = y;
    }
}

class Derived2 extends Derived {
    x = 1
    y = 'hello';
}

var r = new Derived(); // error
var r2 = new Derived2(1); // error
var r3 = new Derived('', '');

class Base2<T> {
    a: T;
    constructor(x: T) { this.a = x; }
}

class D<T> extends Base {
    b: T = null;
    constructor(y: T, z: T) {
        super(2);
        this.b = y;
    }
}


class D2<T extends Date> extends D<T> {
    x = 2
    y: T = null;
}

var d = new D2(); // error
var d2 = new D2(new Date()); // error
var d3 = new D2(new Date(), new Date()); // ok`,
      [],
    );
  });
  test("classConstructorAccessibility", async () => {
    await expectPass(
      `
class C {
    public constructor(public x: number) { }
}

class D {
    private constructor(public x: number) { }
}

class E {
    protected constructor(public x: number) { }
}

var c = new C(1);
var d = new D(1); // error
var e = new E(1); // error

namespace Generic {
    class C<T> {
        public constructor(public x: T) { }
    }

    class D<T> {
        private constructor(public x: T) { }
    }

    class E<T> {
        protected constructor(public x: T) { }
    }

    var c = new C(1);
    var d = new D(1); // error
    var e = new E(1); // error
}
`,
      [],
    );
  });
  test("classConstructorAccessibility2", async () => {
    await expectPass(
      `
class BaseA {
    public constructor(public x: number) { }
    createInstance() { new BaseA(1); }
}

class BaseB {
    protected constructor(public x: number) { }
    createInstance() { new BaseB(2); }
}

class BaseC {
    private constructor(public x: number) { }
    createInstance() { new BaseC(3); }
    static staticInstance() { new BaseC(4); }
}

class DerivedA extends BaseA {
    constructor(public x: number) { super(x); }
    createInstance() { new DerivedA(5); }
    createBaseInstance() { new BaseA(6); }
    static staticBaseInstance() { new BaseA(7); }
}

class DerivedB extends BaseB {
    constructor(public x: number) { super(x); }
    createInstance() { new DerivedB(7); }
    createBaseInstance() { new BaseB(8); } // ok
    static staticBaseInstance() { new BaseB(9); } // ok
}

class DerivedC extends BaseC { // error
    constructor(public x: number) { super(x); }
    createInstance() { new DerivedC(9); }
    createBaseInstance() { new BaseC(10); } // error
    static staticBaseInstance() { new BaseC(11); } // error
}

var ba = new BaseA(1);
var bb = new BaseB(1); // error
var bc = new BaseC(1); // error

var da = new DerivedA(1);
var db = new DerivedB(1);
var dc = new DerivedC(1);
`,
      [],
    );
  });
  test("classConstructorAccessibility3", async () => {
    await expectPass(
      `
class Foo {
     constructor(public x: number) { }
}

class Bar {
    public constructor(public x: number) { }
}

class Baz {
    protected constructor(public x: number) { }
}

class Qux {
     private constructor(public x: number) { }
}

// b is public
let a = Foo;
a = Bar;
a = Baz; // error Baz is protected
a = Qux; // error Qux is private

// b is protected
let b = Baz;
b = Foo;
b = Bar;
b = Qux; // error Qux is private

// c is private
let c = Qux;
c = Foo;
c = Bar;
c = Baz;`,
      [],
    );
  });
  test("classConstructorAccessibility4", async () => {
    await expectPass(
      `
class A {
    private constructor() { }

    method() {
        class B {
            method() {
                new A(); // OK
            }
        }

        class C extends A { // OK
        }
    }
}

class D {
    protected constructor() { }

    method() {
        class E {
            method() {
                new D(); // OK
            }
        }

        class F extends D { // OK
        }
    }
}`,
      [],
    );
  });
  test("classConstructorAccessibility5", async () => {
    await expectPass(
      `class Base {
    protected constructor() { }
}
class Derived extends Base {
    static make() { new Base() } // ok
}

class Unrelated {
    static fake() { new Base() } // error
}
`,
      [],
    );
  });
  test("classConstructorOverloadsAccessibility", async () => {
    await expectPass(
      `
class A {
	public constructor(a: boolean) // error
	protected constructor(a: number) // error
	private constructor(a: string)
	private constructor() { 
		
	}
}

class B {
	protected constructor(a: number) // error
	constructor(a: string)
	constructor() { 
		
	}
}

class C {
	protected constructor(a: number)
	protected constructor(a: string)
	protected constructor() { 
		
	}
}

class D {
	constructor(a: number)
	constructor(a: string)
	public constructor() { 
		
	}
}`,
      [],
    );
  });
  test("classConstructorParametersAccessibility", async () => {
    await expectPass(
      `class C1 {
    constructor(public x: number) { }
}
declare var c1: C1;
c1.x // OK


class C2 {
    constructor(private p: number) { }
}
declare var c2: C2;
c2.p // private, error


class C3 {
    constructor(protected p: number) { }
}
declare var c3: C3;
c3.p // protected, error
class Derived extends C3 {
    constructor(p: number) {
        super(p);
        this.p; // OK
    }
}
`,
      [],
    );
  });
  test("classConstructorParametersAccessibility2", async () => {
    await expectPass(
      `class C1 {
    constructor(public x?: number) { }
}
declare var c1: C1;
c1.x // OK


class C2 {
    constructor(private p?: number) { }
}
declare var c2: C2;
c2.p // private, error


class C3 {
    constructor(protected p?: number) { }
}
declare var c3: C3;
c3.p // protected, error
class Derived extends C3 {
    constructor(p: number) {
        super(p);
        this.p; // OK
    }
}
`,
      [],
    );
  });
  test("classConstructorParametersAccessibility3", async () => {
    await expectPass(
      `class Base {
    constructor(protected p: number) { }
}

class Derived extends Base {
    constructor(public p: number) {
        super(p);
        this.p; // OK
    }
}

var d: Derived;
d.p;  // public, OK`,
      [],
    );
  });
  test("classWithTwoConstructorDefinitions", async () => {
    await expectPass(
      `class C {
    constructor() { } // error
    constructor(x) { } // error
}

class D<T> {
    constructor(x: T) { } // error
    constructor(x: T, y: T) { } // error
}`,
      [],
    );
  });
  test("constructorDefaultValuesReferencingThis", async () => {
    await expectPass(
      `class C {
    public baseProp = 1;
    constructor(x = this) { }
}

class D<T> {
    constructor(x = this) { }
}

class E<T> {
    constructor(public x = this) { }
}

class F extends C {
    constructor(y = this.baseProp) {
        super();
    }
}
`,
      [],
    );
  });
  test("constructorImplementationWithDefaultValues", async () => {
    await expectPass(
      `class C {
    constructor(x);
    constructor(x = 1) {
        var y = x;
    }
}

class D<T> {
    constructor(x);
    constructor(x:T = null) {
        var y = x;
    }
}

class E<T extends Date> {
    constructor(x);
    constructor(x: T = null) {
        var y = x;
    }
}`,
      [],
    );
  });
  test("constructorImplementationWithDefaultValues2", async () => {
    await expectPass(
      `class C {
    constructor(x);
    constructor(public x: string = 1) { // error
        var y = x;
    }
}

class D<T, U> {
    constructor(x: T, y: U);
    constructor(x: T = 1, public y: U = x) { // error
        var z = x;
    }
}

class E<T extends Date> {
    constructor(x);
    constructor(x: T = new Date()) { // error
        var y = x;
    }
}`,
      [],
    );
  });
  test("constructorOverloadsWithDefaultValues", async () => {
    await expectPass(
      `class C {
    foo: string;
    constructor(x = 1); // error
    constructor() {
    }
}

class D<T> {
    foo: string;
    constructor(x = 1); // error
    constructor() {
    }
}`,
      [],
    );
  });
  test("constructorOverloadsWithOptionalParameters", async () => {
    await expectPass(
      `class C {
    foo: string;
    constructor(x?, y?: any[]); 
    constructor() {
    }
}

class D<T> {
    foo: string;
    constructor(x?, y?: any[]); 
    constructor() {
    }
}`,
      [],
    );
  });
  test("constructorParameterProperties", async () => {
    await expectPass(
      `class C {
    y: string;
    constructor(private x: string, protected z: string) { }
}

declare var c: C;
var r = c.y;
var r2 = c.x; // error
var r3 = c.z; // error

class D<T> {
    y: T;
    constructor(a: T, private x: T, protected z: T) { }
}

declare var d: D<string>;
var r = d.y;
var r2 = d.x; // error
var r3 = d.a; // error
var r4 = d.z; // error
`,
      [],
    );
  });
  test("constructorParameterProperties2", async () => {
    await expectPass(
      `class C {
    y: number;
    constructor(y: number) { } // ok
}

declare var c: C;
var r = c.y;

class D {
    y: number;
    constructor(public y: number) { } // error
}

declare var d: D;
var r2 = d.y;

class E {
    y: number;
    constructor(private y: number) { } // error
}

declare var e: E;
var r3 = e.y; // error

class F {
    y: number;
    constructor(protected y: number) { } // error
}

declare var f: F;
var r4 = f.y; // error
`,
      [],
    );
  });
  test("declarationEmitReadonly", async () => {
    await expectPass(
      `
class C {
    constructor(readonly x: number) {}
}`,
      [],
    );
  });
  test("readonlyConstructorAssignment", async () => {
    await expectPass(
      `// Tests that readonly parameter properties behave like regular readonly properties

class A {
    constructor(readonly x: number) {
        this.x = 0;
    }
}

class B extends A {
    constructor(x: number) {
        super(x);
        // Fails, x is readonly
        this.x = 1;
    }
}

class C extends A {
    // This is the usual behavior of readonly properties:
    // if one is redeclared in a base class, then it can be assigned to.
    constructor(readonly x: number) {
        super(x);
        this.x = 1;
    }
}

class D {
    constructor(private readonly x: number) {
        this.x = 0;
    }
}

// Fails, can't redeclare readonly property
class E extends D {
    constructor(readonly x: number) {
        super(x);
        this.x = 1;
    }
}
`,
      [],
    );
  });
  test("readonlyInAmbientClass", async () => {
    await expectPass(
      `declare class C{
	constructor(readonly x: number);
	method(readonly x: number);
}`,
      [],
    );
  });
  test("readonlyInConstructorParameters", async () => {
    await expectError(
      `class C {
    constructor(readonly x: number) {}
}
new C(1).x = 2;

class E {
    constructor(readonly public x: number) {}
}

class F {
    constructor(private readonly x: number) {}
}
new F(1).x;`,
      [],
    );
  });
  test("readonlyReadonly", async () => {
    await expectPass(
      `class C {
    readonly readonly x: number;
    constructor(readonly readonly y: number) {}
}`,
      [],
    );
  });
  test("constructorWithAssignableReturnExpression", async () => {
    await expectPass(
      `// a class constructor may return an expression, it must be assignable to the class instance type to be valid

class C {
    constructor() {
        return 1;
    }
}

class D {
    x: number;
    constructor() {
        return 1; // error
    }
}

class E {
    x: number;
    constructor() {
        return { x: 1 };
    }
}

class F<T> {
    x: T;
    constructor() {
        return { x: 1 }; // error
    }
}

class G<T> {
    x: T;
    constructor() {
        return { x: <T>null };
    }
}`,
      [],
    );
  });
  test("constructorWithExpressionLessReturn", async () => {
    await expectPass(
      `class C {
    constructor() {
        return;
    }
}

class D {
    x: number;
    constructor() {
        return;
    }
}

class E {
    constructor(public x: number) {
        return;
    }
}

class F<T> {
    constructor(public x: T) {
        return;
    }
}`,
      [],
    );
  });
  test("quotedConstructors", async () => {
    await expectPass(
      `class C {
    "constructor"() {
        console.log(this);
    }
}

class D {
    'constructor'() {
        console.log(this);
    }
}

class E {
    ['constructor']() {
        console.log(this);
    }
}

new class {
    "constructor"() {
        console.log(this);
    }
};

var o = { "constructor"() {} };

class F {
    "\\x63onstructor"() {
        console.log(this);
    }
}`,
      [],
    );
  });
  test("derivedClassConstructorWithoutSuperCall", async () => {
    await expectError(
      `// derived class constructors must contain a super call

class Base {
    x: string;
}

class Derived extends Base {
    constructor() { // error
    }
}

class Base2<T> {
    x: T;
}

class Derived2<T> extends Base2<T> {
    constructor() { // error for no super call (nested scopes don't count)
        var r2 = () => super(); // error for misplaced super call (nested function)
    }
}

class Derived3<T> extends Base2<T> {
    constructor() { // error
        var r = function () { super() } // error
    }
}

class Derived4<T> extends Base2<T> {
    constructor() {
        var r = super(); // ok
    }
}`,
      [],
    );
  });
  test("derivedClassParameterProperties", async () => {
    await expectPass(
      `// ordering of super calls in derived constructors matters depending on other class contents

class Base {
    x: string;
}

class Derived extends Base {
    constructor(y: string) {
        var a = 1;
        super();
    }
}

class Derived2 extends Base {
    constructor(public y: string) {
        var a = 1;
        super();
    }
}

class Derived3 extends Base {
    constructor(public y: string) {
        super();
        var a = 1;
    }
}

class Derived4 extends Base {
    a = 1;
    constructor(y: string) {
        var b = 2;
        super();
    }
}

class Derived5 extends Base {
    a = 1;
    constructor(y: string) {
        super();
        var b = 2;
    }
}

class Derived6 extends Base {
    a: number;
    constructor(y: string) {
        this.a = 1;
        var b = 2;
        super();
    }
}

class Derived7 extends Base {
    a = 1;
    b: number;
    constructor(y: string) {
        this.a = 3;
        this.b = 3;
        super();
    }
}

class Derived8 extends Base {
    a = 1;
    b: number;
    constructor(y: string) {
        super();
        this.a = 3;
        this.b = 3;        
    }
}

// generic cases of Derived7 and Derived8
class Base2<T> { x: T; }

class Derived9<T> extends Base2<T> {
    a = 1;
    b: number;
    constructor(y: string) {
        this.a = 3;
        this.b = 3;
        super();
    }
}

class Derived10<T> extends Base2<T> {
    a = 1;
    b: number;
    constructor(y: string) {
        super();
        this.a = 3;
        this.b = 3;
    }
}`,
      [],
    );
  });
  test("derivedClassSuperCallsInNonConstructorMembers", async () => {
    await expectError(
      `// error to use super calls outside a constructor

class Base {
    x: string;
}

class Derived extends Base {
    a: super();
    b() {
        super();
    }
    get C() {
        super();
        return 1;
    }
    set C(v) {
        super();
    }

    static a: super();
    static b() {
        super();
    }
    static get C() {
        super();
        return 1;
    }
    static set C(v) {
        super();
    }
}`,
      [],
    );
  });
  test("derivedClassSuperCallsWithThisArg", async () => {
    await expectPass(
      `class Base {
    x: string;
    constructor(a) { }
}

class Derived extends Base {
    constructor() {
        super(this); // ok
    }
}

class Derived2 extends Base {
    constructor(public a: string) {
        super(this); // error
    }
}

class Derived3 extends Base {
    constructor(public a: string) {
        super(() => this); // error
    }
}

class Derived4 extends Base {
    constructor(public a: string) {
        super(function () { return this; }); // ok
    }
}`,
      [],
    );
  });
  test("derivedClassSuperProperties", async () => {
    await expectPass(
      `
declare const decorate: any;

class Base {
    constructor(a?) { }

    receivesAnything(param?) { }
}

class Derived1 extends Base {
    prop = true;
    constructor() {
        super.receivesAnything();
        super();
    }
}

class Derived2 extends Base {
    prop = true;
    constructor() {
        super.receivesAnything(this);
        super();
    }
}

class Derived3 extends Base {
    prop = true;
    constructor() {
        super.receivesAnything();
        super(this);
    }
}

class Derived4 extends Base {
    prop = true;
    constructor() {
        super.receivesAnything(this);
        super(this);
    }
}

class Derived5 extends Base {
    prop = true;
    constructor() {
        super();
        super.receivesAnything();
    }
}

class Derived6 extends Base {
    prop = true;
    constructor() {
        super(this);
        super.receivesAnything();
    }
}

class Derived7 extends Base {
    prop = true;
    constructor() {
        super();
        super.receivesAnything(this);
    }
}

class Derived8 extends Base {
    prop = true;
    constructor() {
        super(this);
        super.receivesAnything(this);
    }
}

class DerivedWithArrowFunction extends Base {
    prop = true;
    constructor() {
        (() => this)();
        super();
    }
}

class DerivedWithArrowFunctionParameter extends Base {
    prop = true;
    constructor() {
        const lambda = (param = this) => {};
        super();
    }
}

class DerivedWithDecoratorOnClass extends Base {
    prop = true;
    constructor() {
        @decorate(this)
        class InnerClass { }

        super();
    }
}

class DerivedWithDecoratorOnClassMethod extends Base {
    prop = true;
    constructor() {
        class InnerClass {
            @decorate(this)
            innerMethod() { }
        }

        super();
    }
}

class DerivedWithDecoratorOnClassProperty extends Base {
    prop = true;
    constructor() {
        class InnerClass {
            @decorate(this)
            innerProp = true;
        }

        super();
    }
}

class DerivedWithFunctionDeclaration extends Base {
    prop = true;
    constructor() {
        function declaration() {
            return this;
        }
        super();
    }
}

class DerivedWithFunctionDeclarationAndThisParam extends Base {
    prop = true;
    constructor() {
        function declaration(param = this) {
            return param;
        }
        super();
    }
}

class DerivedWithFunctionExpression extends Base {
    prop = true;
    constructor() {
        (function () {
            return this;
        })();
        super();
    }
}

class DerivedWithParenthesis extends Base {
    prop = true;
    constructor() {
        (super());
    }
}

class DerivedWithParenthesisAfterStatement extends Base {
    prop = true;
    constructor() {
        this.prop;
        (super());
    }
}

class DerivedWithParenthesisBeforeStatement extends Base {
    prop = true;
    constructor() {
        (super());
        this.prop;
    }
}

class DerivedWithClassDeclaration extends Base {
    prop = true;
    constructor() {
        class InnerClass {
            private method() {
                return this;
            }
            private property = 7;
            constructor() {
                this.property;
                this.method();
            }
        }
        super();
    }
}

class DerivedWithClassDeclarationExtendingMember extends Base {
    memberClass = class { };
    constructor() {
        class InnerClass extends this.memberClass {
            private method() {
                return this;
            }
            private property = 7;
            constructor() {
                super();
                this.property;
                this.method();
            }
        }
        super();
    }
}

class DerivedWithClassExpression extends Base {
    prop = true;
    constructor() {
        console.log(class {
            private method() {
                return this;
            }
            private property = 7;
            constructor() {
                this.property;
                this.method();
            }
        });
        super();
    }
}

class DerivedWithClassExpressionExtendingMember extends Base {
    memberClass = class { };
    constructor() {
        console.log(class extends this.memberClass { });
        super();
    }
}

class DerivedWithDerivedClassExpression extends Base {
    prop = true;
    constructor() {
        console.log(class extends Base {
            constructor() {
                super();
            }
            public foo() {
                return this;
            }
            public bar = () => this;
        });
        super();
    }
}

class DerivedWithNewDerivedClassExpression extends Base {
    prop = true;
    constructor() {
        console.log(new class extends Base {
            constructor() {
                super();
            }
        }());
        super();
    }
}

class DerivedWithObjectAccessors extends Base {
    prop = true;
    constructor() {
        const obj = {
            get prop() {
                return true;
            },
            set prop(param) {
                this._prop = param;
            }
        };
        super();
    }
}

class DerivedWithObjectAccessorsUsingThisInKeys extends Base {
    propName = "prop";
    constructor() {
        const obj = {
            _prop: "prop",
            get [this.propName]() {
                return true;
            },
            set [this.propName](param) {
                this._prop = param;
            }
        };
        super();
    }
}

class DerivedWithObjectAccessorsUsingThisInBodies extends Base {
    propName = "prop";
    constructor() {
        const obj = {
            _prop: "prop",
            get prop() {
                return this._prop;
            },
            set prop(param) {
                this._prop = param;
            }
        };
        super();
    }
}

class DerivedWithObjectComputedPropertyBody extends Base {
    propName = "prop";
    constructor() {
        const obj = {
            prop: this.propName,
        };
        super();
    }
}

class DerivedWithObjectComputedPropertyName extends Base {
    propName = "prop";
    constructor() {
        const obj = {
            [this.propName]: true,
        };
        super();
    }
}

class DerivedWithObjectMethod extends Base {
    prop = true;
    constructor() {
        const obj = {
            getProp() {
                return this;
            },
        };
        super();
    }
}

let a, b;

const DerivedWithLoops = [
    class extends Base {
        prop = true;
        constructor() {
            for(super();;) {}
        }
    },
    class extends Base {
        prop = true;
        constructor() {
            for(a; super();) {}
        }
    },
    class extends Base {
        prop = true;
        constructor() {
            for(a; b; super()) {}
        }
    },
    class extends Base {
        prop = true;
        constructor() {
            for(; ; super()) { break; }
        }
    },
    class extends Base {
        prop = true;
        constructor() {
            for (const x of super()) {}
        }
    },
    class extends Base {
        prop = true;
        constructor() {
            while (super()) {}
        }
    },
    class extends Base {
        prop = true;
        constructor() {
            do {} while (super());
        }
    },
    class extends Base {
        prop = true;
        constructor() {
            if (super()) {}
        }
    },
    class extends Base {
        prop = true;
        constructor() {
            switch (super()) {}
        }
    },
]
`,
      [],
    );
  });
  test("derivedClassSuperStatementPosition", async () => {
    await expectPass(
      `
class DerivedBasic extends Object {
    prop = 1;
    constructor() {
        super();
    }
}

class DerivedAfterParameterDefault extends Object {
    x1: boolean;
    x2: boolean;
    constructor(x = false) {
        this.x1 = x;
        super(x);
        this.x2 = x;
    }
}

class DerivedAfterRestParameter extends Object {
    x1: boolean[];
    x2: boolean[];
    constructor(...x: boolean[]) {
        this.x1 = x;
        super(x);
        this.x2 = x;
    }
}

class DerivedComments extends Object {
    x: any;
    constructor() {
        // c1
        console.log(); // c2
        // c3
        super(); // c4
        // c5
        this.x = null; // c6
        // c7
    }
}

class DerivedCommentsInvalidThis extends Object {
    x: any;
    constructor() {
        // c0
        this;
        // c1
        console.log(); // c2
        // c3
        super(); // c4
        // c5
        this.x = null; // c6
        // c7
    }
}

class DerivedInConditional extends Object {
    prop = 1;
    constructor() {
        Math.random()
            ? super(1)
            : super(0);
    }
}

class DerivedInIf extends Object {
    prop = 1;
    constructor() {
        if (Math.random()) {
            super(1);
        }
        else {
            super(0);
        }
    }
}

class DerivedInBlockWithProperties extends Object {
    prop = 1;
    constructor(private paramProp = 2) {
        {
            super();
        }
    }
}

class DerivedInConditionalWithProperties extends Object {
    prop = 1;
    constructor(private paramProp = 2) {
        if (Math.random()) {
            super(1);
        } else {
            super(0);
        }
    }
}
`,
      [],
    );
  });
  test("emitStatementsBeforeSuperCall", async () => {
    await expectPass(
      `
class Base {
}
class Sub extends Base {
    // @ts-ignore
    constructor(public p: number) {
        console.log('hi'); // should emit before super
        super();
    }
    field = 0;
}

class Test extends Base {
    prop: number;
    // @ts-ignore
    constructor(public p: number) {
        1; // should emit before super
        super();
        this.prop = 1;
    }
}`,
      [],
    );
  });
  test("emitStatementsBeforeSuperCallWithDefineFields", async () => {
    await expectPass(
      `
class Base {
}
class Sub extends Base {
    // @ts-ignore
    constructor(public p: number) {
        console.log('hi');
        super();
    }
    field = 0;
}

class Test extends Base {
    prop: number;
    // @ts-ignore
    constructor(public p: number) {
        1;
        super();
        this.prop = 1;
    }
}`,
      [],
    );
  });
  test("superCallInConstructorWithNoBaseType", async () => {
    await expectError(
      `class C {
    constructor() {
        super(); // error
    }
}

class D<T> {
    public constructor(public x: T) {
        super(); // error
    }
}`,
      [],
    );
  });
  test("superPropertyInConstructorBeforeSuperCall", async () => {
    await expectPass(
      `class B {
    constructor(x?: string) {}
    x(): string { return ""; }
}
class C1 extends B {
    constructor() {
        super.x();
        super();
    }
}
class C2 extends B {
    constructor() {
        super(super.x());
    }
}`,
      [],
    );
  });
  test("privateIndexer", async () => {
    await expectPass(
      `// private indexers not allowed

class C {
    private [x: string]: string;
}

class D {
    private [x: number]: string;
}

class E<T> {
    private [x: string]: T;
}`,
      [],
    );
  });
  test("privateIndexer2", async () => {
    await expectError(
      `// private indexers not allowed

var x = {
    private [x: string]: string;
}

var y: {
    private[x: string]: string;
}`,
      [],
    );
  });
  test("publicIndexer", async () => {
    await expectPass(
      `// public indexers not allowed

class C {
    public [x: string]: string;
}

class D {
    public [x: number]: string;
}

class E<T> {
    public [x: string]: T;
}`,
      [],
    );
  });
  test("staticIndexers", async () => {
    await expectPass(
      `// static indexers not allowed

class C {
    static [x: string]: string;
}

class D {
    static [x: number]: string;
}

class E<T> {
    static [x: string]: T;
}`,
      [],
    );
  });
  test("classPropertyAsPrivate", async () => {
    await expectPass(
      `class C {
    private x: string;
    private get y() { return null; }
    private set y(x) { }
    private foo() { }

    private static a: string;
    private static get b() { return null; }
    private static set b(x) { }
    private static foo() { }
}

declare var c: C;
// all errors
c.x;
c.y;
c.y = 1;
c.foo();

C.a;
C.b();
C.b = 1;
C.foo();`,
      [],
    );
  });
  test("classPropertyAsProtected", async () => {
    await expectPass(
      `class C {
    protected x: string;
    protected get y() { return null; }
    protected set y(x) { }
    protected foo() { }

    protected static a: string;
    protected static get b() { return null; }
    protected static set b(x) { }
    protected static foo() { }
}

declare var c: C;
// all errors
c.x;
c.y;
c.y = 1;
c.foo();

C.a;
C.b();
C.b = 1;
C.foo();`,
      [],
    );
  });
  test("classPropertyIsPublicByDefault", async () => {
    await expectPass(
      `class C {
    x: string;
    get y() { return null; }
    set y(x) { }
    foo() { }

    static a: string;
    static get b() { return null; }
    static set b(x) { }
    static foo() { }
}

var c: C;
c.x;
c.y;
c.y = 1;
c.foo();

C.a;
C.b();
C.b = 1;
C.foo();`,
      [],
    );
  });
  test("privateClassPropertyAccessibleWithinClass", async () => {
    await expectPass(
      `// no errors

class C {
    private x: string;
    private get y() { return this.x; }
    private set y(x) { this.y = this.x; }
    private foo() { return this.foo; }

    private static x: string;
    private static get y() { return this.x; }
    private static set y(x) { this.y = this.x; }
    private static foo() { return this.foo; }
    private static bar() { this.foo(); }
}

// added level of function nesting
class C2 {
    private x: string;
    private get y() { () => this.x; return null; }
    private set y(x) { () => { this.y = this.x; } }
    private foo() { () => this.foo; }

    private static x: string;
    private static get y() { () => this.x; return null; }
    private static set y(x) {
        () => { this.y = this.x; }
     }
    private static foo() { () => this.foo; }
    private static bar() { () => this.foo(); }
}
`,
      [],
    );
  });
  test("privateClassPropertyAccessibleWithinNestedClass", async () => {
    await expectPass(
      `// no errors

class C {
    private x: string;
    private get y() { return this.x; }
    private set y(x) { this.y = this.x; }
    private foo() { return this.foo; }

    private static x: string;
    private static get y() { return this.x; }
    private static set y(x) { this.y = this.x; }
    private static foo() { return this.foo; }
    private static bar() { this.foo(); }

    private bar() {
        class C2 {
            private foo() {
                let x: C;
                var x1 = x.foo;
                var x2 = x.bar;
                var x3 = x.x;
                var x4 = x.y;

                var sx1 = C.x;
                var sx2 = C.y;
                var sx3 = C.bar;
                var sx4 = C.foo;

                let y = new C();
                var y1 = y.foo;
                var y2 = y.bar;
                var y3 = y.x;
                var y4 = y.y;
            }
        }
    }
}`,
      [],
    );
  });
  test("privateInstanceMemberAccessibility", async () => {
    await expectError(
      `class Base {
    private foo: string;
}

class Derived extends Base {
    x = super.foo; // error
    y() {
        return super.foo; // error
    }
    z: typeof super.foo; // error

    a: this.foo; // error
}`,
      [],
    );
  });
  test("privateProtectedMembersAreNotAccessibleDestructuring", async () => {
    await expectPass(
      `class K {
    private priv;
    protected prot;
    private privateMethod() { }
    m() {
        let { priv: a, prot: b } = this; // ok
        let { priv, prot } = new K(); // ok
    }
}
class C extends K {
    m2() {
        let { priv: a } = this; // error
        let { prot: b } = this; // ok
    }
}
let k = new K();
let { priv } = k; // error
let { prot } = k; // error
let { privateMethod } = k; // error
let { priv: a, prot: b, privateMethod: pm } = k; // error
function f({ priv, prot, privateMethod }: K) {

}
`,
      [],
    );
  });
  test("privateStaticMemberAccessibility", async () => {
    await expectPass(
      `class Base {
    private static foo: string;
}

class Derived extends Base {
    static bar = Base.foo; // error
    bing = () => Base.foo; // error
}`,
      [],
    );
  });
  test("privateStaticNotAccessibleInClodule", async () => {
    await expectPass(
      `// Any attempt to access a private property member outside the class body that contains its declaration results in a compile-time error.

class C {
    private foo: string;
    private static bar: string;
}

namespace C {
    export var y = C.bar; // error
}`,
      [],
    );
  });
  test("privateStaticNotAccessibleInClodule2", async () => {
    await expectPass(
      `// Any attempt to access a private property member outside the class body that contains its declaration results in a compile-time error.

class C {
    private foo: string;
    private static bar: string;
}

class D extends C {
    baz: number;   
}

namespace D {
    export var y = D.bar; // error
}`,
      [],
    );
  });
  test("protectedClassPropertyAccessibleWithinClass", async () => {
    await expectPass(
      `// no errors

class C {
    protected x: string;
    protected get y() { return this.x; }
    protected set y(x) { this.y = this.x; }
    protected foo() { return this.foo; }

    protected static x: string;
    protected static get y() { return this.x; }
    protected static set y(x) { this.y = this.x; }
    protected static foo() { return this.foo; }
    protected static bar() { this.foo(); }
}

// added level of function nesting
class C2 {
    protected x: string;
    protected get y() { () => this.x; return null; }
    protected set y(x) { () => { this.y = this.x; } }
    protected foo() { () => this.foo; }

    protected static x: string;
    protected static get y() { () => this.x; return null; }
    protected static set y(x) {
        () => { this.y = this.x; }
     }
    protected static foo() { () => this.foo; }
    protected static bar() { () => this.foo(); }
}
`,
      [],
    );
  });
  test("protectedClassPropertyAccessibleWithinNestedClass", async () => {
    await expectPass(
      `// no errors

class C {
    protected x: string;
    protected get y() { return this.x; }
    protected set y(x) { this.y = this.x; }
    protected foo() { return this.foo; }

    protected static x: string;
    protected static get y() { return this.x; }
    protected static set y(x) { this.y = this.x; }
    protected static foo() { return this.foo; }
    protected static bar() { this.foo(); }

    protected bar() {
        class C2 {
            protected foo() {
                let x: C;
                var x1 = x.foo;
                var x2 = x.bar;
                var x3 = x.x;
                var x4 = x.y;

                var sx1 = C.x;
                var sx2 = C.y;
                var sx3 = C.bar;
                var sx4 = C.foo;

                let y = new C();
                var y1 = y.foo;
                var y2 = y.bar;
                var y3 = y.x;
                var y4 = y.y;
            }
        }
    }
}`,
      [],
    );
  });
  test("protectedClassPropertyAccessibleWithinNestedSubclass", async () => {
    await expectPass(
      `
class B {
    protected x: string;
    protected static x: string;
}

class C extends B {
    protected get y() { return this.x; }
    protected set y(x) { this.y = this.x; }
    protected foo() { return this.x; }

    protected static get y() { return this.x; }
    protected static set y(x) { this.y = this.x; }
    protected static foo() { return this.x; }
    protected static bar() { this.foo(); }
    
    protected bar() { 
        class D {
            protected foo() {
                var c = new C();
                var c1 = c.y;
                var c2 = c.x;
                var c3 = c.foo;
                var c4 = c.bar;
                var c5 = c.z; // error
                
                var sc1 = C.x;
                var sc2 = C.y;
                var sc3 = C.foo;
                var sc4 = C.bar;
            }
        }
    }
}

class E extends C {
    protected z: string;
}`,
      [],
    );
  });
  test("protectedClassPropertyAccessibleWithinNestedSubclass1", async () => {
    await expectPass(
      `class Base {
    protected x!: string;
    method() {
        class A {
            methoda() {
                var b: Base = undefined as any;
                var d1: Derived1 = undefined as any;
                var d2: Derived2 = undefined as any;
                var d3: Derived3 = undefined as any;
                var d4: Derived4 = undefined as any;

                b.x;            // OK, accessed within their declaring class
                d1.x;           // OK, accessed within their declaring class
                d2.x;           // OK, accessed within their declaring class
                d3.x;           // Error, redefined in a subclass, can only be accessed in the declaring class or one of its subclasses
                d4.x;           // OK, accessed within their declaring class
            }
        }
    }
}

class Derived1 extends Base {
    method1() {
        class B {
            method1b() {
                var b: Base = undefined as any;
                var d1: Derived1 = undefined as any;
                var d2: Derived2 = undefined as any;
                var d3: Derived3 = undefined as any;
                var d4: Derived4 = undefined as any;

                b.x;            // Error, isn't accessed through an instance of the enclosing class
                d1.x;           // OK, accessed within a class derived from their declaring class, and through an instance of the enclosing class
                d2.x;           // Error, isn't accessed through an instance of the enclosing class
                d3.x;           // Error, redefined in a subclass, can only be accessed in the declaring class or one of its subclasses
                d4.x;           // Error, isn't accessed through an instance of the enclosing class
            }
        }
    }
}

class Derived2 extends Base {
    method2() {
        class C {
            method2c() {
                var b: Base = undefined as any;
                var d1: Derived1 = undefined as any;
                var d2: Derived2 = undefined as any;
                var d3: Derived3 = undefined as any;
                var d4: Derived4 = undefined as any;

                b.x;            // Error, isn't accessed through an instance of the enclosing class
                d1.x;           // Error, isn't accessed through an instance of the enclosing class
                d2.x;           // OK, accessed within a class derived from their declaring class, and through an instance of the enclosing class
                d3.x;           // Error, redefined in a subclass, can only be accessed in the declaring class or one of its subclasses
                d4.x;           // OK, accessed within a class derived from their declaring class, and through an instance of the enclosing class or one of its subclasses
            }
        }
    }
}

class Derived3 extends Derived1 {
    protected x!: string;
    method3() {
        class D {
            method3d() {
                var b: Base = undefined as any;
                var d1: Derived1 = undefined as any;
                var d2: Derived2 = undefined as any;
                var d3: Derived3 = undefined as any;
                var d4: Derived4 = undefined as any;

                b.x;            // Error, isn't accessed through an instance of the enclosing class
                d1.x;           // Error, isn't accessed through an instance of the enclosing class
                d2.x;           // Error, isn't accessed through an instance of the enclosing class
                d3.x;           // OK, accessed within their declaring class
                d4.x;           // Error, isn't accessed through an instance of the enclosing class
            }
        }
    }
}

class Derived4 extends Derived2 {
    method4() {
        class E {
            method4e() {
                var b: Base = undefined as any;
                var d1: Derived1 = undefined as any;
                var d2: Derived2 = undefined as any;
                var d3: Derived3 = undefined as any;
                var d4: Derived4 = undefined as any;

                b.x;            // Error, isn't accessed through an instance of the enclosing class
                d1.x;           // Error, isn't accessed through an instance of the enclosing class
                d2.x;           // Error, isn't accessed through an instance of the enclosing class
                d3.x;           // Error, redefined in a subclass, can only be accessed in the declaring class or one of its subclasses
                d4.x;           // OK, accessed within a class derived from their declaring class, and through an instance of the enclosing class
            }
        }
    }
}


var b: Base = undefined as any;
var d1: Derived1 = undefined as any;
var d2: Derived2 = undefined as any;
var d3: Derived3 = undefined as any;
var d4: Derived4 = undefined as any;

b.x;                    // Error, neither within their declaring class nor classes derived from their declaring class
d1.x;                   // Error, neither within their declaring class nor classes derived from their declaring class
d2.x;                   // Error, neither within their declaring class nor classes derived from their declaring class
d3.x;                   // Error, neither within their declaring class nor classes derived from their declaring class
d4.x;                   // Error, neither within their declaring class nor classes derived from their declaring class`,
      [],
    );
  });
  test("protectedClassPropertyAccessibleWithinSubclass", async () => {
    await expectPass(
      `// no errors

class B {
    protected x: string;
    protected static x: string;
}

class C extends B {
    protected get y() { return this.x; }
    protected set y(x) { this.y = this.x; }
    protected foo() { return this.x; }
    protected bar() { return this.foo(); }

    protected static get y() { return this.x; }
    protected static set y(x) { this.y = this.x; }
    protected static foo() { return this.x; }
    protected static bar() { this.foo(); }
}
`,
      [],
    );
  });
  test("protectedClassPropertyAccessibleWithinSubclass2", async () => {
    await expectPass(
      `class Base {
    protected x!: string;
    method() {
        var b: Base = undefined as any;
        var d1: Derived1 = undefined as any;
        var d2: Derived2 = undefined as any;
        var d3: Derived3 = undefined as any;
        var d4: Derived4 = undefined as any;

        b.x;            // OK, accessed within their declaring class
        d1.x;           // OK, accessed within their declaring class
        d2.x;           // OK, accessed within their declaring class
        d3.x;           // Error, redefined in a subclass, can only be accessed in the declaring class or one of its subclasses
        d4.x;           // OK, accessed within their declaring class
    }
}

class Derived1 extends Base {
    method1() {
        var b: Base = undefined as any;
        var d1: Derived1 = undefined as any;
        var d2: Derived2 = undefined as any;
        var d3: Derived3 = undefined as any;
        var d4: Derived4 = undefined as any;

        b.x;            // Error, isn't accessed through an instance of the enclosing class
        d1.x;           // OK, accessed within a class derived from their declaring class, and through an instance of the enclosing class
        d2.x;           // Error, isn't accessed through an instance of the enclosing class
        d3.x;           // Error, redefined in a subclass, can only be accessed in the declaring class or one of its subclasses
        d4.x;           // Error, isn't accessed through an instance of the enclosing class
    }
}

class Derived2 extends Base {
    method2() {
        var b: Base = undefined as any;
        var d1: Derived1 = undefined as any;
        var d2: Derived2 = undefined as any;
        var d3: Derived3 = undefined as any;
        var d4: Derived4 = undefined as any;

        b.x;            // Error, isn't accessed through an instance of the enclosing class
        d1.x;           // Error, isn't accessed through an instance of the enclosing class
        d2.x;           // OK, accessed within a class derived from their declaring class, and through an instance of the enclosing class
        d3.x;           // Error, redefined in a subclass, can only be accessed in the declaring class or one of its subclasses
        d4.x;           // OK, accessed within a class derived from their declaring class, and through an instance of the enclosing class or one of its subclasses
    }
}

class Derived3 extends Derived1 {
    protected x!: string;
    method3() {
        var b: Base = undefined as any;
        var d1: Derived1 = undefined as any;
        var d2: Derived2 = undefined as any;
        var d3: Derived3 = undefined as any;
        var d4: Derived4 = undefined as any;

        b.x;            // Error, isn't accessed through an instance of the enclosing class
        d1.x;           // Error, isn't accessed through an instance of the enclosing class
        d2.x;           // Error, isn't accessed through an instance of the enclosing class
        d3.x;           // OK, accessed within their declaring class
        d4.x;           // Error, isn't accessed through an instance of the enclosing class
    }
}

class Derived4 extends Derived2 {
    method4() {
        var b: Base = undefined as any;
        var d1: Derived1 = undefined as any;
        var d2: Derived2 = undefined as any;
        var d3: Derived3 = undefined as any;
        var d4: Derived4 = undefined as any;

        b.x;            // Error, isn't accessed through an instance of the enclosing class
        d1.x;           // Error, isn't accessed through an instance of the enclosing class
        d2.x;           // Error, isn't accessed through an instance of the enclosing class
        d3.x;           // Error, redefined in a subclass, can only be accessed in the declaring class or one of its subclasses
        d4.x;           // OK, accessed within a class derived from their declaring class, and through an instance of the enclosing class
    }
}


var b: Base = undefined as any;
var d1: Derived1 = undefined as any;
var d2: Derived2 = undefined as any;
var d3: Derived3 = undefined as any;
var d4: Derived4 = undefined as any;

b.x;                    // Error, neither within their declaring class nor classes derived from their declaring class
d1.x;                   // Error, neither within their declaring class nor classes derived from their declaring class
d2.x;                   // Error, neither within their declaring class nor classes derived from their declaring class
d3.x;                   // Error, neither within their declaring class nor classes derived from their declaring class
d4.x;                   // Error, neither within their declaring class nor classes derived from their declaring class`,
      [],
    );
  });
  test("protectedClassPropertyAccessibleWithinSubclass3", async () => {
    await expectPass(
      `class Base {
    protected x: string;
    method() {
        this.x;            // OK, accessed within their declaring class
    }
}

class Derived extends Base {
    method1() {
        this.x;            // OK, accessed within a subclass of the declaring class
        super.x;           // Error, x is not public
    }
}`,
      [],
    );
  });
  test("protectedInstanceMemberAccessibility", async () => {
    await expectPass(
      `class A {
    protected x!: string;
    protected f(): string {
        return "hello";
    }
}

class B extends A {
    protected y!: string;
    g() {
        var t1 = this.x;
        var t2 = this.f();
        var t3 = this.y;
        var t4 = this.z;     // error

        var s1 = super.x;    // error
        var s2 = super.f();
        var s3 = super.y;    // error
        var s4 = super.z;    // error

        var a: A = undefined as any;
        var a1 = a.x;    // error
        var a2 = a.f();  // error
        var a3 = a.y;    // error
        var a4 = a.z;    // error

        var b: B = undefined as any;
        var b1 = b.x;
        var b2 = b.f();
        var b3 = b.y;
        var b4 = b.z;    // error

        var c: C = undefined as any;
        var c1 = c.x;    // error
        var c2 = c.f();  // error
        var c3 = c.y;    // error
        var c4 = c.z;    // error
    }
}

class C extends A {
    protected z!: string;
}
`,
      [],
    );
  });
  test("protectedStaticClassPropertyAccessibleWithinSubclass", async () => {
    await expectPass(
      `class Base {
    protected static x: string;
    static staticMethod() {
        Base.x;         // OK, accessed within their declaring class
        Derived1.x;     // OK, accessed within their declaring class
        Derived2.x;     // OK, accessed within their declaring class
        Derived3.x;     // Error, redefined in a subclass, can only be accessed in the declaring class or one of its subclasses
    }
}

class Derived1 extends Base {
    static staticMethod1() {
        Base.x;         // OK, accessed within a class derived from their declaring class
        Derived1.x;     // OK, accessed within a class derived from their declaring class
        Derived2.x;     // OK, accessed within a class derived from their declaring class
        Derived3.x;     // Error, redefined in a subclass, can only be accessed in the declaring class or one of its subclasses
    }
}

class Derived2 extends Base {
    static staticMethod2() {
        Base.x;         // OK, accessed within a class derived from their declaring class
        Derived1.x;     // OK, accessed within a class derived from their declaring class
        Derived2.x;     // OK, accessed within a class derived from their declaring class
        Derived3.x;     // Error, redefined in a subclass, can only be accessed in the declaring class or one of its subclasses
    }
}

class Derived3 extends Derived1 {
    protected static x: string;
    static staticMethod3() {
        Base.x;         // OK, accessed within a class derived from their declaring class
        Derived1.x;     // OK, accessed within a class derived from their declaring class
        Derived2.x;     // OK, accessed within a class derived from their declaring class
        Derived3.x;     // OK, accessed within their declaring class
    }
}


Base.x;         // Error, neither within their declaring class nor classes derived from their declaring class
Derived1.x;     // Error, neither within their declaring class nor classes derived from their declaring class
Derived2.x;     // Error, neither within their declaring class nor classes derived from their declaring class
Derived3.x;     // Error, neither within their declaring class nor classes derived from their declaring class`,
      [],
    );
  });
  test("protectedStaticClassPropertyAccessibleWithinSubclass2", async () => {
    await expectPass(
      `class Base {
    protected static x: string;
    static staticMethod() {
        this.x;         // OK, accessed within their declaring class
    }
}

class Derived1 extends Base {
    static staticMethod1() {
        this.x;         // OK, accessed within a class derived from their declaring class
        super.x;        // Error, x is not public
    }
}

class Derived2 extends Derived1 {
    protected static x: string;
    static staticMethod3() {
        this.x;         // OK, accessed within a class derived from their declaring class
        super.x;        // Error, x is not public
    }
}`,
      [],
    );
  });
  test("protectedStaticNotAccessibleInClodule", async () => {
    await expectPass(
      `// Any attempt to access a private property member outside the class body that contains its declaration results in a compile-time error.

class C {
    public static foo: string;
    protected static bar: string;
}

namespace C {
    export var f = C.foo; // OK
    export var b = C.bar; // error
}`,
      [],
    );
  });
  test("genericSetterInClassType", async () => {
    await expectPass(
      `
namespace Generic {
    class C<T> {
        get y(): T {
            return 1 as never;
        }
        set y(v) { }
    }

    var c = new C<number>();
    c.y = c.y;

    class Box<T> {
        #value!: T;
        
        get value() {
            return this.#value;
        }
    
        set value(value) {
            this.#value = value;
        }
    }
    
    new Box<number>().value = 3;
}`,
      [],
    );
  });
  test("genericSetterInClassTypeJsDoc", async () => {
    await expectPass(
      `
/**
 * @template T
 */
 class Box {
    #value;

    /** @param {T} initialValue */
    constructor(initialValue) {
        this.#value = initialValue;
    }
    
    /** @type {T} */
    get value() {
        return this.#value;
    }

    set value(value) {
        this.#value = value;
    }
}

new Box(3).value = 3;
`,
      [],
    );
  });
  test("indexersInClassType", async () => {
    await expectPass(
      `class C {
    [x: number]: Date;
    [x: string]: Object;
    1: Date;
    'a': {}

    fn() {
        return this;
    }
}

var c = new C();
var r = c.fn();
var r2 = r[1];
var r3 = r.a

`,
      [],
    );
  });
  test("instancePropertiesInheritedIntoClassType", async () => {
    await expectPass(
      `namespace NonGeneric {
    class C {
        x: string;
        get y() {
            return 1;
        }
        set y(v) { }
        fn() { return this; }
        constructor(public a: number, private b: number) { }
    }

    class D extends C { e: string; }

    var d = new D(1, 2);
    var r = d.fn();
    var r2 = r.x;
    var r3 = r.y;
    r.y = 4;
    var r6 = d.y(); // error

}

namespace Generic {
    class C<T, U> {
        x: T;
        get y() {
            return null;
        }
        set y(v: U) { }
        fn() { return this; }
        constructor(public a: T, private b: U) { }
    }

    class D<T, U> extends C<T, U> { e: T; }

    var d = new D(1, '');
    var r = d.fn();
    var r2 = r.x;
    var r3 = r.y;
    r.y = '';
    var r6 = d.y(); // error
}`,
      [],
    );
  });
  test("instancePropertyInClassType", async () => {
    await expectPass(
      `namespace NonGeneric {
    class C {
        x: string;
        get y() {
            return 1;
        }
        set y(v) { }
        fn() { return this; }
        constructor(public a: number, private b: number) { }
    }

    var c = new C(1, 2);
    var r = c.fn();
    var r2 = r.x;
    var r3 = r.y;
    r.y = 4;
    var r6 = c.y(); // error

}

namespace Generic {
    class C<T,U> {
        x: T;
        get y() {
            return null;
        }
        set y(v: U) { }
        fn() { return this; }
        constructor(public a: T, private b: U) { }
    }

    var c = new C(1, '');
    var r = c.fn();
    var r2 = r.x;
    var r3 = r.y;
    r.y = '';
    var r6 = c.y(); // error
}`,
      [],
    );
  });
  test("staticPropertyNotInClassType", async () => {
    await expectPass(
      `namespace NonGeneric {
    class C {
        fn() { return this; }
        static get x() { return 1; }
        static set x(v) { }
        constructor(public a: number, private b: number) { }
        static foo: string; // not reflected in class type
    }

    namespace C {
        export var bar = ''; // not reflected in class type
    }

    var c = new C(1, 2);
    var r = c.fn();
    var r4 = c.foo; // error
    var r5 = c.bar; // error
    var r6 = c.x; // error
}

namespace Generic {
    class C<T, U> {
        fn() { return this; }
        static get x() { return 1; }
        static set x(v) { }
        constructor(public a: T, private b: U) { }
        static foo: T; // not reflected in class type
    }

    namespace C {
        export var bar = ''; // not reflected in class type
    }

    var c = new C(1, '');
    var r = c.fn();
    var r4 = c.foo; // error
    var r5 = c.bar; // error
    var r6 = c.x; // error
}`,
      [],
    );
  });
  test("classWithBaseClassButNoConstructor", async () => {
    await expectPass(
      `class Base {
    constructor(x: number) { }
}

class C extends Base {
    foo: string;
}

var r = C;
var c = new C(); // error
var c2 = new C(1); // ok

class Base2<T,U> {
    constructor(x: T) { }
}

class D<T,U> extends Base2<T,U> {
    foo: U;
}

var r2 = D;
var d = new D(); // error
var d2 = new D(1); // ok

// specialized base class
class D2<T, U> extends Base2<string, number> {
    foo: U;
}

var r3 = D2;
var d3 = new D(); // error
var d4 = new D(1); // ok

class D3 extends Base2<string, number> {
    foo: string;
}

var r4 = D3;
var d5 = new D(); // error
var d6 = new D(1); // ok`,
      [],
    );
  });
  test("classWithConstructors", async () => {
    await expectPass(
      `namespace NonGeneric {
    class C {
        constructor(x: string) { }
    }

    var c = new C(); // error
    var c2 = new C(''); // ok

    class C2 {
        constructor(x: number);
        constructor(x: string);
        constructor(x: any) { }
    }

    var c3 = new C2(); // error
    var c4 = new C2(''); // ok
    var c5 = new C2(1); // ok

    class D extends C2 { }

    var d = new D(); // error
    var d2 = new D(1); // ok
    var d3 = new D(''); // ok
}

namespace Generics {
    class C<T> {
        constructor(x: T) { }
    }

    var c = new C(); // error
    var c2 = new C(''); // ok

    class C2<T,U> {
        constructor(x: T);
        constructor(x: T, y: U);
        constructor(x: any) { }
    }

    var c3 = new C2(); // error
    var c4 = new C2(''); // ok
    var c5 = new C2(1, 2); // ok

    class D<T, U> extends C2<T, U> { }

    var d = new D(); // error
    var d2 = new D(1); // ok
    var d3 = new D(''); // ok
}`,
      [],
    );
  });
  test("classWithNoConstructorOrBaseClass", async () => {
    await expectPass(
      `class C {
    x: string;
}

var c = new C();
var r = C;

class D<T,U> {
    x: T;
    y: U;
}

var d = new D();
var d2 = new D<string, number>();
var r2 = D;
`,
      [],
    );
  });
  test("classWithStaticMembers", async () => {
    await expectPass(
      `class C {
    static fn() { return this; }
    static get x() { return 1; }
    static set x(v) { }
    constructor(public a: number, private b: number) { }
    static foo: string; 
}

var r = C.fn();
var r2 = r.x;
var r3 = r.foo;

class D extends C {
    bar: string;
}

var r = D.fn();
var r2 = r.x;
var r3 = r.foo;`,
      [],
    );
  });
  test("constructorHasPrototypeProperty", async () => {
    await expectPass(
      `namespace NonGeneric {
    class C {
        foo: string;
    }

    class D extends C {
        bar: string;
    }

    var r = C.prototype;
    r.foo;
    var r2 = D.prototype;
    r2.bar;
}

namespace Generic {
    class C<T,U> {
        foo: T;
        bar: U;
    }

    class D<T,U> extends C<T,U> {
        baz: T;
        bing: U;
    }

    var r = C.prototype; // C<any, any>
    var ra = r.foo; // any
    var r2 = D.prototype; // D<any, any>
    var rb = r2.baz; // any
}`,
      [],
    );
  });
  test("derivedClassFunctionOverridesBaseClassAccessor", async () => {
    await expectPass(
      `class Base {
    get x() {
        return 1;
    }
    set x(v) {
    }
}

// error
class Derived extends Base {
    x() {
        return 1;
    }
}`,
      [],
    );
  });
  test("derivedClassIncludesInheritedMembers", async () => {
    await expectPass(
      `class Base {
    a: string;
    b() { }
    get c() { return ''; }
    set c(v) { }

    static r: string;
    static s() { }
    static get t() { return ''; }
    static set t(v) { }

    constructor(x) { }
}

class Derived extends Base {
}

var d: Derived = new Derived(1);
var r1 = d.a;
var r2 = d.b();
var r3 = d.c;
d.c = '';
var r4 = Derived.r;
var r5 = Derived.s();
var r6 = Derived.t;
Derived.t = '';

class Base2 {
    [x: string]: Object;
    [x: number]: Date;
}

class Derived2 extends Base2 {
}

var d2: Derived2;
var r7 = d2[''];
var r8 = d2[1];

`,
      [],
    );
  });
  test("derivedClassOverridesIndexersWithAssignmentCompatibility", async () => {
    await expectPass(
      `class Base {
    [x: string]: Object;
}

// ok, use assignment compatibility
class Derived extends Base {
    [x: string]: any;
}

class Base2 {
    [x: number]: Object;
}

// ok, use assignment compatibility
class Derived2 extends Base2 {
    [x: number]: any;
}`,
      [],
    );
  });
  test("derivedClassOverridesPrivates", async () => {
    await expectPass(
      `class Base {
    private x: { foo: string };
}

class Derived extends Base {
    private x: { foo: string; bar: string; }; // error
}

class Base2 {
    private static y: { foo: string };
}

class Derived2 extends Base2 {
    private static y: { foo: string; bar: string; }; // error
}`,
      [],
    );
  });
  test("derivedClassOverridesProtectedMembers", async () => {
    await expectPass(
      `
var x: { foo: string; }
var y: { foo: string; bar: string; }

class Base {
    protected a: typeof x;
    protected b(a: typeof x) { }
    protected get c() { return x; }
    protected set c(v: typeof x) { }
    protected d: (a: typeof x) => void;

    protected static r: typeof x;
    protected static s(a: typeof x) { }
    protected static get t() { return x; }
    protected static set t(v: typeof x) { }
    protected static u: (a: typeof x) => void;

    constructor(a: typeof x) { }
}

class Derived extends Base {
    protected a: typeof y;
    protected b(a: typeof y) { }
    protected get c() { return y; }
    protected set c(v: typeof y) { }
    protected d: (a: typeof y) => void;

    protected static r: typeof y;
    protected static s(a: typeof y) { }
    protected static get t() { return y; }
    protected static set t(a: typeof y) { }
    protected static u: (a: typeof y) => void;

    constructor(a: typeof y) { super(x) }
}
`,
      [],
    );
  });
  test("derivedClassOverridesProtectedMembers2", async () => {
    await expectPass(
      `var x: { foo: string; }
var y: { foo: string; bar: string; }

class Base {
    protected a: typeof x;
    protected b(a: typeof x) { }
    protected get c() { return x; }
    protected set c(v: typeof x) { }
    protected d: (a: typeof x) => void ;

    protected static r: typeof x;
    protected static s(a: typeof x) { }
    protected static get t() { return x; }
    protected static set t(v: typeof x) { }
    protected static u: (a: typeof x) => void ;

constructor(a: typeof x) { }
}

// Increase visibility of all protected members to public
class Derived extends Base {
    a: typeof y;
    b(a: typeof y) { }
    get c() { return y; }
    set c(v: typeof y) { }
    d: (a: typeof y) => void;

    static r: typeof y;
    static s(a: typeof y) { }
    static get t() { return y; }
    static set t(a: typeof y) { }
    static u: (a: typeof y) => void;

    constructor(a: typeof y) { super(a); }
}

var d: Derived = new Derived(y);
var r1 = d.a;
var r2 = d.b(y);
var r3 = d.c;
var r3a = d.d;
d.c = y;
var r4 = Derived.r;
var r5 = Derived.s(y);
var r6 = Derived.t;
var r6a = Derived.u;
Derived.t = y;

class Base2 {
    [i: string]: Object;
    [i: number]: typeof x;
}

class Derived2 extends Base2 {
    [i: string]: typeof x;
    [i: number]: typeof y;
}

var d2: Derived2;
var r7 = d2[''];
var r8 = d2[1];

`,
      [],
    );
  });
  test("derivedClassOverridesProtectedMembers3", async () => {
    await expectPass(
      `
var x: { foo: string; }
var y: { foo: string; bar: string; }

class Base {
    a: typeof x;
    b(a: typeof x) { }
    get c() { return x; }
    set c(v: typeof x) { }
    d: (a: typeof x) => void;

    static r: typeof x;
    static s(a: typeof x) { }
    static get t() { return x; }
    static set t(v: typeof x) { }
    static u: (a: typeof x) => void;

    constructor(a: typeof x) {}
}

// Errors
// decrease visibility of all public members to protected
class Derived1 extends Base {
    protected a: typeof x;
    constructor(a: typeof x) { super(a); }
}

class Derived2 extends Base {
    protected b(a: typeof x) { }
    constructor(a: typeof x) { super(a); }
}

class Derived3 extends Base {
    protected get c() { return x; }
    constructor(a: typeof x) { super(a); }
}

class Derived4 extends Base {
    protected set c(v: typeof x) { }
    constructor(a: typeof x) { super(a); }
}

class Derived5 extends Base {
    protected d: (a: typeof x) => void ;
    constructor(a: typeof x) { super(a); }
}

class Derived6 extends Base {
    protected static r: typeof x;
    constructor(a: typeof x) { super(a); }
}

class Derived7 extends Base {
    protected static s(a: typeof x) { }
    constructor(a: typeof x) { super(a); }
}

class Derived8 extends Base {
    protected static get t() { return x; }
    constructor(a: typeof x) { super(a); }
}

class Derived9 extends Base {
    protected static set t(v: typeof x) { }
    constructor(a: typeof x) { super(a); }
}

class Derived10 extends Base {
    protected static u: (a: typeof x) => void ;
    constructor(a: typeof x) { super(a); }
}`,
      [],
    );
  });
  test("derivedClassOverridesProtectedMembers4", async () => {
    await expectPass(
      `var x: { foo: string; }
var y: { foo: string; bar: string; }

class Base {
    protected a: typeof x;
}

class Derived1 extends Base {
    public a: typeof x;
}

class Derived2 extends Derived1 {
    protected a: typeof x; // Error, parent was public
}`,
      [],
    );
  });
  test("derivedClassOverridesPublicMembers", async () => {
    await expectPass(
      `var x: { foo: string; }
var y: { foo: string; bar: string; }

class Base {
    a: typeof x;
    b(a: typeof x) { }
    get c() { return x; }
    set c(v: typeof x) { }
    d: (a: typeof x) => void;

    static r: typeof x;
    static s(a: typeof x) { }
    static get t() { return x; }
    static set t(v: typeof x) { }
    static u: (a: typeof x) => void;

    constructor(a: typeof x) { }
}

class Derived extends Base {
    a: typeof y;
    b(a: typeof y) { }
    get c() { return y; }
    set c(v: typeof y) { }
    d: (a: typeof y) => void;

    static r: typeof y;
    static s(a: typeof y) { }
    static get t() { return y; }
    static set t(a: typeof y) { }
    static u: (a: typeof y) => void;

    constructor(a: typeof y) { super(x) }
}

var d: Derived = new Derived(y);
var r1 = d.a;
var r2 = d.b(y);
var r3 = d.c;
var r3a = d.d;
d.c = y;
var r4 = Derived.r;
var r5 = Derived.s(y);
var r6 = Derived.t;
var r6a = Derived.u;
Derived.t = y;

class Base2 {
    [i: string]: Object;
    [i: number]: typeof x;
}

class Derived2 extends Base2 {
    [i: string]: typeof x;
    [i: number]: typeof y;
}

var d2: Derived2;
var r7 = d2[''];
var r8 = d2[1];

`,
      [],
    );
  });
  test("derivedClassOverridesWithoutSubtype", async () => {
    await expectPass(
      `class Base {
    x: {
        foo: string;
    }
}

class Derived extends Base {
    x: {
        foo: any;
    }
}

class Base2 {
    static y: {
        foo: string;
    }
}

class Derived2 extends Base2 {
    static y: {
        foo: any;
    }
}`,
      [],
    );
  });
  test("derivedClassTransitivity", async () => {
    await expectPass(
      `// subclassing is not transitive when you can remove required parameters and add optional parameters

class C {
    foo(x: number) { }
}

class D extends C {
    foo() { } // ok to drop parameters
}

class E extends D {
    foo(x?: string) { } // ok to add optional parameters
}

declare var c: C;
declare var d: D;
declare var e: E;
c = e;
var r = c.foo(1);
var r2 = e.foo('');`,
      [],
    );
  });
  test("derivedClassTransitivity2", async () => {
    await expectPass(
      `// subclassing is not transitive when you can remove required parameters and add optional parameters

class C {
    foo(x: number, y: number) { }
}

class D extends C {
    foo(x: number) { } // ok to drop parameters
}

class E extends D {
    foo(x: number, y?: string) { } // ok to add optional parameters
}

declare var c: C;
declare var d: D;
declare var e: E;
c = e;
var r = c.foo(1, 1);
var r2 = e.foo(1, '');`,
      [],
    );
  });
  test("derivedClassTransitivity3", async () => {
    await expectPass(
      `// subclassing is not transitive when you can remove required parameters and add optional parameters

class C<T> {
    foo(x: T, y: T) { }
}

class D<T> extends C<T> {
    foo(x: T) { } // ok to drop parameters
}

class E<T> extends D<T> {
    foo(x: T, y?: number) { } // ok to add optional parameters
}

declare var c: C<string>;
declare var d: D<string>;
declare var e: E<string>;
c = e;
var r = c.foo('', '');
var r2 = e.foo('', 1);`,
      [],
    );
  });
  test("derivedClassTransitivity4", async () => {
    await expectPass(
      `// subclassing is not transitive when you can remove required parameters and add optional parameters on protected members

class C {
    protected foo(x: number) { }
}

class D extends C {
    protected foo() { } // ok to drop parameters
}

class E extends D {
    public foo(x?: string) { } // ok to add optional parameters
}

declare var c: C;
declare var d: D;
declare var e: E;
c = e;
var r = c.foo(1);
var r2 = e.foo('');`,
      [],
    );
  });
  test("derivedClassWithAny", async () => {
    await expectPass(
      `class C {
    x: number;
    get X(): number { return 1; }
    foo(): number {
        return 1;
    }

    static y: number;
    static get Y(): number {
        return 1;
    }
    static bar(): number {
        return 1;
    }
}

class D extends C {
    x: any;
    get X(): any {
        return null;
    }
    foo(): any {
        return 1;
    }

    static y: any;
    static get Y(): any {
        return null;
    }
    static bar(): any {
        return null;
    }
}

// if D is a valid class definition than E is now not safe tranisitively through C
class E extends D {
    x: string;
    get X(): string{ return ''; }
    foo(): string {
        return '';
    }

    static y: string;
    static get Y(): string {
        return '';
    }
    static bar(): string {
        return '';
    }
}

declare var c: C;
declare var d: D;
declare var e: E;

c = d;
c = e;
var r = c.foo(); // e.foo would return string
`,
      [],
    );
  });
  test("derivedClassWithPrivateInstanceShadowingProtectedInstance", async () => {
    await expectPass(
      `
class Base {
    protected x: string;
    protected fn(): string {
        return '';
    }

    protected get a() { return 1; }
    protected set a(v) { }
}

// error, not a subtype
class Derived extends Base {
    private x: string; 
    private fn(): string {
        return '';
    }

    private get a() { return 1; }
    private set a(v) { }
}
`,
      [],
    );
  });
  test("derivedClassWithPrivateInstanceShadowingPublicInstance", async () => {
    await expectPass(
      `class Base {
    public x: string;
    public fn(): string {
        return '';
    }

    public get a() { return 1; }
    public set a(v) { }
}

// error, not a subtype
class Derived extends Base {
    private x: string; 
    private fn(): string {
        return '';
    }

    private get a() { return 1; }
    private set a(v) { }
}

var r = Base.x; // ok
var r2 = Derived.x; // error

var r3 = Base.fn(); // ok
var r4 = Derived.fn(); // error

var r5 = Base.a; // ok
Base.a = 2; // ok

var r6 = Derived.a; // error
Derived.a = 2; // error`,
      [],
    );
  });
  test("derivedClassWithPrivateStaticShadowingProtectedStatic", async () => {
    await expectPass(
      `
class Base {
    protected static x: string;
    protected static fn(): string {
        return '';
    }

    protected static get a() { return 1; }
    protected static set a(v) { }
}

// should be error
class Derived extends Base {
    private static x: string; 
    private static fn(): string {
        return '';
    }

    private static get a() { return 1; }
    private static set a(v) { }
}`,
      [],
    );
  });
  test("derivedClassWithPrivateStaticShadowingPublicStatic", async () => {
    await expectPass(
      `class Base {
    public static x: string;
    public static fn(): string {
        return '';
    }

    public static get a() { return 1; }
    public static set a(v) { }
}

// BUG 847404
// should be error
class Derived extends Base {
    private static x: string; 
    private static fn(): string {
        return '';
    }

    private static get a() { return 1; }
    private static set a(v) { }
}

var r = Base.x; // ok
var r2 = Derived.x; // error

var r3 = Base.fn(); // ok
var r4 = Derived.fn(); // error

var r5 = Base.a; // ok
Base.a = 2; // ok

var r6 = Derived.a; // error
Derived.a = 2; // error`,
      [],
    );
  });
  test("derivedGenericClassWithAny", async () => {
    await expectPass(
      `class C<T extends number> {
    x: T;
    get X(): T { return null; }
    foo(): T {
        return null;
    }
}

class D extends C<number> {
    x: any;
    get X(): any {
        return null;
    }
    foo(): any {
        return 1;
    }

    static y: any;
    static get Y(): any {
        return null;
    }
    static bar(): any {
        return null;
    }
}

// if D is a valid class definition than E is now not safe tranisitively through C
class E<T extends string> extends D {
    x: T;
    get X(): T { return ''; } // error
    foo(): T {
        return ''; // error
    }
}

declare var c: C<number>;
declare var d: D;
declare var e: E<string>;

c = d;
c = e;
var r = c.foo(); // e.foo would return string`,
      [],
    );
  });
  test("thisAndSuperInStaticMembers1", async () => {
    await expectPass(
      `
declare class B {
    static a: any;
    static f(): number;
    a: number;
    f(): number;
}

class C extends B {
    static x: any = undefined!;
    static y1 = this.x;
    static y2 = this.x();
    static y3 = this?.x();
    static y4 = this[("x")]();
    static y5 = this?.[("x")]();
    static z1 = super.a;
    static z2 = super["a"];
    static z3 = super.f();
    static z4 = super["f"]();
    static z5 = super.a = 0;
    static z6 = super.a += 1;
    static z7 = (() => { super.a = 0; })();
    static z8 = [super.a] = [0];
    static z9 = [super.a = 0] = [0];
    static z10 = [...super.a] = [0];
    static z11 = { x: super.a } = { x: 0 };
    static z12 = { x: super.a = 0 } = { x: 0 };
    static z13 = { ...super.a } = { x: 0 };
    static z14 = ++super.a;
    static z15 = --super.a;
    static z16 = ++super[("a")];
    static z17 = super.a++;
    static z18 = super.a\`\`;

    // these should be unaffected
    x = 1;
    y = this.x;
    z = super.f();
}
`,
      [],
    );
  });
  test("thisAndSuperInStaticMembers2", async () => {
    await expectPass(
      `
declare class B {
    static a: any;
    static f(): number;
    a: number;
    f(): number;
}

class C extends B {
    static x: any = undefined!;
    static y1 = this.x;
    static y2 = this.x();
    static y3 = this?.x();
    static y4 = this[("x")]();
    static y5 = this?.[("x")]();
    static z1 = super.a;
    static z2 = super["a"];
    static z3 = super.f();
    static z4 = super["f"]();
    static z5 = super.a = 0;
    static z6 = super.a += 1;
    static z7 = (() => { super.a = 0; })();
    static z8 = [super.a] = [0];
    static z9 = [super.a = 0] = [0];
    static z10 = [...super.a] = [0];
    static z11 = { x: super.a } = { x: 0 };
    static z12 = { x: super.a = 0 } = { x: 0 };
    static z13 = { ...super.a } = { x: 0 };
    static z14 = ++super.a;
    static z15 = --super.a;
    static z16 = ++super[("a")];
    static z17 = super.a++;
    static z18 = super.a\`\`;

    // these should be unaffected
    x = 1;
    y = this.x;
    z = super.f();
}
`,
      [],
    );
  });
  test("thisAndSuperInStaticMembers3", async () => {
    await expectPass(
      `
declare class B {
    static a: any;
    static f(): number;
    a: number;
    f(): number;
}

class C extends B {
    static x: any = undefined!;
    static y1 = this.x;
    static y2 = this.x();
    static y3 = this?.x();
    static y4 = this[("x")]();
    static y5 = this?.[("x")]();
    static z3 = super.f();
    static z4 = super["f"]();
    
    // these should be unaffected
    x = 1;
    y = this.x;
    z = super.f();
}`,
      [],
    );
  });
  test("thisAndSuperInStaticMembers4", async () => {
    await expectPass(
      `
declare class B {
    static a: any;
    static f(): number;
    a: number;
    f(): number;
}

class C extends B {
    static x: any = undefined!;
    static y1 = this.x;
    static y2 = this.x();
    static y3 = this?.x();
    static y4 = this[("x")]();
    static y5 = this?.[("x")]();
    static z3 = super.f();
    static z4 = super["f"]();
    
    // these should be unaffected
    x = 1;
    y = this.x;
    z = super.f();
}`,
      [],
    );
  });
  test("typeOfThisInInstanceMember", async () => {
    await expectPass(
      `class C {
    x = this;
    foo() {
        return this;
    }
    constructor(x: number) {
        var t = this;
        t.x;
        t.y;
        t.z;
        var r = t.foo();
    }

    get y() {
        return this;
    }
}

declare var c: C;
// all ok
var r = c.x;
var ra = c.x.x.x;
var r2 = c.y;
var r3 = c.foo();
var rs = [r, r2, r3];

rs.forEach(x => {
    x.foo;
    x.x;
    x.y;
});`,
      [],
    );
  });
  test("typeOfThisInInstanceMember2", async () => {
    await expectPass(
      `class C<T> {
    x = this;
    foo() {
        return this;
    }
    constructor(x: T) {
        var t = this;
        t.x;
        t.y;
        t.z;
        var r = t.foo();
    }

    get y() {
        return this;
    }

    z: T;
}

var c: C<string>;
// all ok
var r = c.x;
var ra = c.x.x.x;
var r2 = c.y;
var r3 = c.foo();
var r4 = c.z;
var rs = [r, r2, r3];

rs.forEach(x => {
    x.foo;
    x.x;
    x.y;
    x.z;
});`,
      [],
    );
  });
  test("typeOfThisInstanceMemberNarrowedWithLoopAntecedent", async () => {
    await expectPass(
      `// #31995
type State = {
    type: "numberVariant";
    data: number;
} | {
    type: "stringVariant";
    data: string;
};

class SomeClass {
    state!: State;
    method() {
        while (0) { }
        this.state.data;
        if (this.state.type === "stringVariant") {
            const s: string = this.state.data;
        }
    }
}

class SomeClass2 {
    state!: State;
    method() {
        const c = false;
        while (c) { }
        if (this.state.type === "numberVariant") {
            this.state.data;
        }
        let n: number = this.state?.data; // This should be an error
    }
}`,
      [],
    );
  });
  test("typeOfThisInStaticMembers", async () => {
    await expectPass(
      `class C {
    constructor(x: number) { }
    static foo: number;
    static bar() {
        // type of this is the constructor function type
        var t = this;
        return this;
    }
}

var t = C.bar();
// all ok
var r2 = t.foo + 1;
var r3 = t.bar();
var r4 = new t(1);

class C2<T> {
    static test: number;
    constructor(x: string) { }
    static foo: string;
    static bar() {
        // type of this is the constructor function type
        var t = this;
        return this;
    }
}

var t2 = C2.bar();
// all ok
var r5 = t2.foo + 1;
var r6 = t2.bar();
var r7 = new t2('');

`,
      [],
    );
  });
  test("typeOfThisInStaticMembers10", async () => {
    await expectPass(
      `
declare const foo: any;

@foo
class C {
    static a = 1;
    static b = this.a + 1;
}

@foo
class D extends C {
    static c = 2;
    static d = this.c + 1;
    static e = super.a + this.c + 1;
    static f = () => this.c + 1;
    static ff = function () { this.c + 1 }
    static foo () {
        return this.c + 1;
    }
    static get fa () {
        return this.c + 1;
    }
    static set fa (v: number) {
        this.c = v + 1;
    }
}

class CC {
    static a = 1;
    static b = this.a + 1;
}

class DD extends CC {
    static c = 2;
    static d = this.c + 1;
    static e = super.a + this.c + 1;
    static f = () => this.c + 1;
    static ff = function () { this.c + 1 }
    static foo () {
        return this.c + 1;
    }
    static get fa () {
        return this.c + 1;
    }
    static set fa (v: number) {
        this.c = v + 1;
    }
}
`,
      [],
    );
  });
  test("typeOfThisInStaticMembers11", async () => {
    await expectPass(
      `
declare const foo: any;

@foo
class C {
    static a = 1;
    static b = this.a + 1;
}

@foo
class D extends C {
    static c = 2;
    static d = this.c + 1;
    static e = super.a + this.c + 1;
    static f = () => this.c + 1;
    static ff = function () { this.c + 1 }
    static foo () {
        return this.c + 1;
    }
    static get fa () {
        return this.c + 1;
    }
    static set fa (v: number) {
        this.c = v + 1;
    }
}

class CC {
    static a = 1;
    static b = this.a + 1;
}

class DD extends CC {
    static c = 2;
    static d = this.c + 1;
    static e = super.a + this.c + 1;
    static f = () => this.c + 1;
    static ff = function () { this.c + 1 }
    static foo () {
        return this.c + 1;
    }
    static get fa () {
        return this.c + 1;
    }
    static set fa (v: number) {
        this.c = v + 1;
    }
}
`,
      [],
    );
  });
  test("typeOfThisInStaticMembers12", async () => {
    await expectPass(
      `
class C {
    static readonly c: "foo" = "foo"
    static bar =  class Inner {
        static [this.c] = 123;
        [this.c] = 123;
    }
}
`,
      [],
    );
  });
  test("typeOfThisInStaticMembers13", async () => {
    await expectPass(
      `
class C {
    static readonly c: "foo" = "foo"
    static bar =  class Inner {
        static [this.c] = 123;
        [this.c] = 123;
    }
}
`,
      [],
    );
  });
  test("typeOfThisInStaticMembers2", async () => {
    await expectPass(
      `class C {
    static foo = this; // ok
}

class C2<T> {
    static foo = this; // ok
}`,
      [],
    );
  });
  test("typeOfThisInStaticMembers3", async () => {
    await expectPass(
      `class C {
    static a = 1;
    static b = this.a + 1;
}

class D extends C {
    static c = 2;
    static d = this.c + 1;
    static e = super.a + this.c + 1;
}
`,
      [],
    );
  });
  test("typeOfThisInStaticMembers4", async () => {
    await expectPass(
      `class C {
    static a = 1;
    static b = this.a + 1;
}

class D extends C {
    static c = 2;
    static d = this.c + 1;
    static e = super.a + this.c + 1;
}
`,
      [],
    );
  });
  test("typeOfThisInStaticMembers5", async () => {
    await expectPass(
      `
class C {
    static create = () => new this("yep")

    constructor (private foo: string) {

    }
}
`,
      [],
    );
  });
  test("typeOfThisInStaticMembers6", async () => {
    await expectError(
      `class C {
    static f = 1
}

class D extends C {
    static c = super();
}
`,
      [],
    );
  });
  test("typeOfThisInStaticMembers7", async () => {
    await expectPass(
      `
class C {
    static a = 1;
    static b = this.a + 1;
}

class D extends C {
    static c = 2;
    static d = this.c + 1;
    static e = 1 + (super.a) + (this.c + 1) + 1;
}
`,
      [],
    );
  });
  test("typeOfThisInStaticMembers8", async () => {
    await expectPass(
      `
class C {
    static f = 1;
    static arrowFunctionBoundary = () => this.f + 1;
    static functionExprBoundary = function () { return this.f + 2 };
    static classExprBoundary = class { a = this.f + 3 };
    static functionAndClassDeclBoundary = (() => {
        function foo () {
            return this.f + 4
        }
        class CC {
            a = this.f + 5
            method () {
                return this.f + 6
            }
        }
    })();
}
`,
      [],
    );
  });
  test("typeOfThisInStaticMembers9", async () => {
    await expectError(
      `
class C {
    static f = 1
}

class D extends C {
    static arrowFunctionBoundary = () => super.f + 1;
    static functionExprBoundary = function () { return super.f + 2 };
    static classExprBoundary = class { a = super.f + 3 };
    static functionAndClassDeclBoundary = (() => {
        function foo () {
            return super.f + 4
        }
        class C {
            a = super.f + 5
            method () {
                return super.f +6
            }
        }
    })();
}
`,
      [],
    );
  });
  test("privateNameAccessors", async () => {
    await expectPass(
      `
class A1 {
    get #prop() { return ""; }
    set #prop(param: string) { }

    get #roProp() { return ""; }

    constructor(name: string) {
        this.#prop = "";
        this.#roProp = ""; // Error
        console.log(this.#prop);
        console.log(this.#roProp);
    }
}
`,
      [],
    );
  });
  test("privateNameAccessorsAccess", async () => {
    await expectPass(
      `
class A2 {
    get #prop() { return ""; }
    set #prop(param: string) { }

    constructor() {
        console.log(this.#prop);
        let a: A2 = this;
        a.#prop;
        function  foo (){
            a.#prop;
        }
    }
}
new A2().#prop; // Error

function  foo (){
    new A2().#prop; // Error
}

class B2 {
    m() {
        new A2().#prop;
    }
}
`,
      [],
    );
  });
  test("privateNameAccessorsCallExpression", async () => {
    await expectPass(
      `
class A {
    get #fieldFunc() {  return function() { this.x = 10; } }
    get #fieldFunc2() { return  function(a, ...b) {}; }
    x = 1;
    test() {
        this.#fieldFunc();
        const func = this.#fieldFunc;
        func();
        new this.#fieldFunc();

        const arr = [ 1, 2 ];
        this.#fieldFunc2(0, ...arr, 3);
        const b = new this.#fieldFunc2(0, ...arr, 3);
        const str = this.#fieldFunc2\`head\${1}middle\${2}tail\`;
        this.getInstance().#fieldFunc2\`test\${1}and\${2}\`;
    }
    getInstance() { return new A(); }
}`,
      [],
    );
  });
  test("privateNameAccessorssDerivedClasses", async () => {
    await expectPass(
      `
class Base {
    get #prop(): number { return  123; }
    static method(x: Derived) {
        console.log(x.#prop);
    }
}
class Derived extends Base {
    static method(x: Derived) {
        console.log(x.#prop);
    }
}`,
      [],
    );
  });
  test("privateNameAmbientNoImplicitAny", async () => {
    await expectPass(
      `declare class A {
    #prop;
}
class B {
    #prop;
}`,
      [],
    );
  });
  test("privateNameAndAny", async () => {
    await expectPass(
      `
class A {
    #foo = true;
    static #baz = 10;
    static #m() {}
    method(thing: any) {
        thing.#foo; // OK
        thing.#m();
        thing.#baz;
        thing.#bar; // Error
        thing.#foo();
    }
    methodU(thing: unknown) {
        thing.#foo;
        thing.#m();
        thing.#baz;
        thing.#bar;
        thing.#foo();
    }
    methodN(thing: never) {
        thing.#foo;
        thing.#m();
        thing.#baz;
        thing.#bar;
        thing.#foo();
    }
};
`,
      [],
    );
  });
  test("privateNameAndIndexSignature", async () => {
    await expectPass(
      `
class A {
    [k: string]: any;
    #foo = 3;
    ["#bar"] = this["#bar"]   // Error (private identifiers should not prevent circularity checking for computeds)
    constructor(message: string) {
        this.#f = 3           // Error (index signatures do not implicitly declare private names)
        this["#foo"] = 3;     // Okay (type has index signature and "#foo" does not collide with private identifier #foo)

    }
}
`,
      [],
    );
  });
  test("privateNameAndObjectRestSpread", async () => {
    await expectPass(
      `
class C {
    #prop = 1;
    static #propStatic = 1;

    method(other: C) {
        const obj = { ...other };
        obj.#prop;
        const { ...rest } = other;
        rest.#prop;

        const statics = { ... C};
        statics.#propStatic
        const { ...sRest } = C;
        sRest.#propStatic;
    }
}`,
      [],
    );
  });
  test("privateNameAndPropertySignature", async () => {
    await expectPass(
      `type A = {
    #foo: string;
    #bar(): string;
}

interface B {
    #foo: string;
    #bar(): string;
}

declare const x: {
    #foo: number;
    bar: {
        #baz: string;
        #taz(): string;
    }
    #baz(): string;
};

declare const y: [{ qux: { #quux: 3 } }];`,
      [],
    );
  });
  test("privateNameAndStaticInitializer", async () => {
    await expectPass(
      `
class A {
  #foo = 1;
  static inst = new A();
  #prop = 2;
}`,
      [],
    );
  });
  test("privateNameBadAssignment", async () => {
    await expectPass(
      `
exports.#nope = 1;           // Error (outside class body)
function A() { }
A.prototype.#no = 2;         // Error (outside class body)

class B {}
B.#foo = 3;                  // Error (outside class body)

class C {
    #bar = 6;
    constructor () {
        exports.#bar = 6;    // Error
        this.#foo = 3;       // Error (undeclared)
    }
}`,
      [],
    );
  });
  test("privateNameBadDeclaration", async () => {
    await expectError(
      `function A() { }
A.prototype = {
  #x: 1,         // Error
  #m() {},       // Error
  get #p() { return "" } // Error
}
class B { }
B.prototype = {
  #y: 2,         // Error
  #m() {},       // Error
  get #p() { return "" } // Error
}
class C {
  constructor() {
    this.#z = 3;
  }
}`,
      [],
    );
  });
  test("privateNameBadSuper", async () => {
    await expectPass(
      `class B {};
class A extends B {
  #x;
  constructor() {
    this;
    super();
  }
}`,
      [],
    );
  });
  test("privateNameBadSuperUseDefineForClassFields", async () => {
    await expectPass(
      `class B {};
class A extends B {
  #x;
  constructor() {
    this;
    super();
  }
}`,
      [],
    );
  });
  test("privateNameCircularReference", async () => {
    await expectPass(
      `
class A {
    #foo = this.#bar;
    #bar = this.#foo;
    ["#baz"] = this["#baz"]; // Error (should *not* be private name error)
}`,
      [],
    );
  });
  test("privateNameClassExpressionLoop", async () => {
    await expectPass(
      `const array = [];
for (let i = 0; i < 10; ++i) {
    array.push(class C {
        #myField = "hello";
        #method() {}
        get #accessor() { return 42; }
        set #accessor(val) { }
    });
}`,
      [],
    );
  });
  test("privateNameComputedPropertyName1", async () => {
    await expectPass(
      `
class A {
    #a = 'a';
    #b: string;

    readonly #c = 'c';
    readonly #d: string;

    #e = '';

    constructor() {
        this.#b = 'b';
        this.#d = 'd';
    }

    test() {
        const data: Record<string, string> = { a: 'a', b: 'b', c: 'c', d: 'd', e: 'e' };
        const {
            [this.#a]: a,
            [this.#b]: b,
            [this.#c]: c,
            [this.#d]: d,
            [this.#e = 'e']: e,
        } = data;
        console.log(a, b, c, d, e);

        const a1 = data[this.#a];
        const b1 = data[this.#b];
        const c1 = data[this.#c];
        const d1 = data[this.#d];
        const e1 = data[this.#e];
        console.log(a1, b1, c1, d1);
    }
}

new A().test();

`,
      [],
    );
  });
  test("privateNameComputedPropertyName2", async () => {
    await expectPass(
      `
let getX: (a: A) => number;

class A {
    #x = 100;
    [(getX = (a: A) => a.#x, "_")]() {}
}

console.log(getX(new A));
`,
      [],
    );
  });
  test("privateNameComputedPropertyName3", async () => {
    await expectPass(
      `
class Foo {
    #name;

    constructor(name) {
        this.#name = name;
    }

    getValue(x) {
        const obj = this;

        class Bar {
            #y = 100;

            [obj.#name]() {
                return x + this.#y;
            }
        }

        return new Bar()[obj.#name]();
    }
}

console.log(new Foo("NAME").getValue(100));
`,
      [],
    );
  });
  test("privateNameComputedPropertyName4", async () => {
    await expectPass(
      `// https://github.com/microsoft/TypeScript/issues/44113
class C1 {
    static #qux = 42;
    ["bar"] () {}
}
class C2 {
    static #qux = 42;
    static ["bar"] () {}
}
class C3 {
    static #qux = 42;
    static ["bar"] = "test";
}
`,
      [],
    );
  });
  test("privateNameConstructorReserved", async () => {
    await expectError(
      `
class A {
    #constructor() {}      // Error: \`#constructor\` is a reserved word.
}
`,
      [],
    );
  });
  test("privateNameConstructorSignature", async () => {
    await expectPass(
      `
interface D {
    x: number;
}
class C {
    #x;
    static test() {
        new C().#x = 10;
        const y = new C();
        const z = new y();
        z.x = 123;
    }
}
interface C {
    new (): D;
}`,
      [],
    );
  });
  test("privateNameDeclaration", async () => {
    await expectPass(
      `
class A {
    #foo: string;
    #bar = 6;
    baz: string;
    qux = 6;
    quux(): void {

    }
}
`,
      [],
    );
  });
  test("privateNameDeclarationMerging", async () => {
    await expectPass(
      `
class D {};

class C {
    #x;
    foo () {
        const c = new C();
        c.#x;     // OK
        const d: D = new C();
        d.#x;    // Error
    }
}
interface C {
    new (): D;
}`,
      [],
    );
  });
  test("privateNameDuplicateField", async () => {
    await expectPass(
      `
function Field() {

    // Error
    class A_Field_Field {
        #foo = "foo";
        #foo = "foo";
    }

    // Error
    class A_Field_Method {
        #foo = "foo";
        #foo() { }
    }

    // Error
    class A_Field_Getter {
        #foo = "foo";
        get #foo() { return ""}
    }

    // Error
    class A_Field_Setter {
        #foo = "foo";
        set #foo(value: string) { }
    }

    // Error
    class A_Field_StaticField {
        #foo = "foo";
        static #foo = "foo";
    }

    // Error
    class A_Field_StaticMethod {
        #foo = "foo";
        static #foo() { }
    }

    // Error
    class A_Field_StaticGetter {
        #foo = "foo";
        static get #foo() { return ""}
    }

    // Error
    class A_Field_StaticSetter {
        #foo = "foo";
        static set #foo(value: string) { }
    }
}

function Method() {
    // Error
    class A_Method_Field {
        #foo() { }
        #foo = "foo";
    }

    // Error
    class A_Method_Method {
        #foo() { }
        #foo() { }
    }

    // Error
    class A_Method_Getter {
        #foo() { }
        get #foo() { return ""}
    }

    // Error
    class A_Method_Setter {
        #foo() { }
        set #foo(value: string) { }
    }

    // Error
    class A_Method_StaticField {
        #foo() { }
        static #foo = "foo";
    }

    // Error
    class A_Method_StaticMethod {
        #foo() { }
        static #foo() { }
    }

    // Error
    class A_Method_StaticGetter {
        #foo() { }
        static get #foo() { return ""}
    }

    // Error
    class A_Method_StaticSetter {
        #foo() { }
        static set #foo(value: string) { }
    }
}


function Getter() {
    // Error
    class A_Getter_Field {
        get #foo() { return ""}
        #foo = "foo";
    }

    // Error
    class A_Getter_Method {
        get #foo() { return ""}
        #foo() { }
    }

    // Error
    class A_Getter_Getter {
        get #foo() { return ""}
        get #foo() { return ""}
    }

    //OK
    class A_Getter_Setter {
        get #foo() { return ""}
        set #foo(value: string) { }
    }

    // Error
    class A_Getter_StaticField {
        get #foo() { return ""}
        static #foo() { }
    }

    // Error
    class A_Getter_StaticMethod {
        get #foo() { return ""}
        static #foo() { }
    }

    // Error
    class A_Getter_StaticGetter {
        get #foo() { return ""}
        static get #foo() { return ""}
    }

    // Error
    class A_Getter_StaticSetter {
        get #foo() { return ""}
        static set #foo(value: string) { }
    }
}

function Setter() {
    // Error
    class A_Setter_Field {
        set #foo(value: string) { }
        #foo = "foo";
    }

    // Error
    class A_Setter_Method {
        set #foo(value: string) { }
        #foo() { }
    }

    // OK
    class A_Setter_Getter {
        set #foo(value: string) { }
        get #foo() { return ""}
    }

    // Error
    class A_Setter_Setter {
        set #foo(value: string) { }
        set #foo(value: string) { }
    }

    // Error
    class A_Setter_StaticField {
        set #foo(value: string) { }
        static #foo = "foo";
    }

    // Error
    class A_Setter_StaticMethod {
        set #foo(value: string) { }
        static #foo() { }
    }

    // Error
    class A_Setter_StaticGetter {
        set #foo(value: string) { }
        static get #foo() { return ""}
    }

    // Error
    class A_Setter_StaticSetter {
        set #foo(value: string) { }
        static set #foo(value: string) { }
    }
}

function StaticField() {
    // Error
    class A_StaticField_Field {
        static #foo = "foo";
        #foo = "foo";
    }

    // Error
    class A_StaticField_Method {
        static #foo = "foo";
        #foo() { }
    }

    // Error
    class A_StaticField_Getter {
        static #foo = "foo";
        get #foo() { return ""}
    }

    // Error
    class A_StaticField_Setter {
        static #foo = "foo";
        set #foo(value: string) { }
    }

    // Error
    class A_StaticField_StaticField {
        static #foo = "foo";
        static #foo = "foo";
    }

    // Error
    class A_StaticField_StaticMethod {
        static #foo = "foo";
        static #foo() { }
    }

    // Error
    class A_StaticField_StaticGetter {
        static #foo = "foo";
        static get #foo() { return ""}
    }

    // Error
    class A_StaticField_StaticSetter {
        static #foo = "foo";
        static set #foo(value: string) { }
    }
}

function StaticMethod() {
    // Error
    class A_StaticMethod_Field {
        static #foo() { }
        #foo = "foo";
    }

    // Error
    class A_StaticMethod_Method {
        static #foo() { }
        #foo() { }
    }

    // Error
    class A_StaticMethod_Getter {
        static #foo() { }
        get #foo() { return ""}
    }

    // Error
    class A_StaticMethod_Setter {
        static #foo() { }
        set #foo(value: string) { }
    }

    // Error
    class A_StaticMethod_StaticField {
        static #foo() { }
        static #foo = "foo";
    }

    // Error
    class A_StaticMethod_StaticMethod {
        static #foo() { }
        static #foo() { }
    }

    // Error
    class A_StaticMethod_StaticGetter {
        static #foo() { }
        static get #foo() { return ""}
    }

    // Error
    class A_StaticMethod_StaticSetter {
        static #foo() { }
        static set #foo(value: string) { }
    }
}

function StaticGetter() {

    // Error
    class A_StaticGetter_Field {
        static get #foo() { return ""}
        #foo = "foo";
    }

    // Error
    class A_StaticGetter_Method {
        static get #foo() { return ""}
        #foo() { }
    }

    // Error
    class A_StaticGetter_Getter {
        static get #foo() { return ""}
        get #foo() { return ""}
    }

    // Error
    class A_StaticGetter_Setter {
        static get #foo() { return ""}
        set #foo(value: string) { }
    }

    // Error
    class A_StaticGetter_StaticField {
        static get #foo() { return ""}
        static #foo() { }
    }

    // Error
    class A_StaticGetter_StaticMethod {
        static get #foo() { return ""}
        static #foo() { }
    }

    // Error
    class A_StaticGetter_StaticGetter {
        static get #foo() { return ""}
        static get #foo() { return ""}
    }
    // OK
    class A_StaticGetter_StaticSetter {
        static get #foo() { return ""}
        static set #foo(value: string) { }
    }
}

function StaticSetter() {
    // Error
    class A_StaticSetter_Field {
        static set #foo(value: string) { }
        #foo = "foo";
    }

    // Error
    class A_StaticSetter_Method {
        static set #foo(value: string) { }
        #foo() { }
    }


    // Error
    class A_StaticSetter_Getter {
        static set #foo(value: string) { }
        get #foo() { return ""}
    }

    // Error
    class A_StaticSetter_Setter {
        static set #foo(value: string) { }
        set #foo(value: string) { }
    }

    // Error
    class A_StaticSetter_StaticField {
        static set #foo(value: string) { }
        static #foo = "foo";
    }

    // Error
    class A_StaticSetter_StaticMethod {
        static set #foo(value: string) { }
        static #foo() { }
    }

    // OK
    class A_StaticSetter_StaticGetter {
        static set #foo(value: string) { }
        static get #foo() { return ""}
    }

    // Error
    class A_StaticSetter_StaticSetter {
        static set #foo(value: string) { }
        static set #foo(value: string) { }
    }
}
`,
      [],
    );
  });
  test("privateNameEmitHelpers", async () => {
    await expectPass(
      `

export class C {
    #a = 1;
    #b() { this.#c = 42; }
    set #c(v: number) { this.#a += v; }
}

// these are pre-TS4.3 versions of emit helpers, which only supported private instance fields
export declare function __classPrivateFieldGet<T extends object, V>(receiver: T, state: any): V;
export declare function __classPrivateFieldSet<T extends object, V>(receiver: T, state: any, value: V): V;`,
      [],
    );
  });
  test("privateNameEnum", async () => {
    await expectPass(
      `
enum E {
    #x
}`,
      [],
    );
  });
  test("privateNameES5Ban", async () => {
    await expectPass(
      `
class A {
    constructor() {}
    #field = 123;
    #method() {}
    static #sField = "hello world";
    static #sMethod() {}
    get #acc() { return ""; }
    set #acc(x: string) {}
    static get #sAcc() { return 0; }
    static set #sAcc(x: number) {}
}`,
      [],
    );
  });
  test("privateNameField", async () => {
    await expectPass(
      `
class A {
    #name: string;
    constructor(name: string) {
        this.#name = name;
    }
}`,
      [],
    );
  });
  test("privateNameFieldAccess", async () => {
    await expectPass(
      `
class A {
    #myField = "hello world";
    constructor() {
        console.log(this.#myField);
    }
}
`,
      [],
    );
  });
  test("privateNameFieldAssignment", async () => {
    await expectPass(
      `
class A {
    #field = 0;
    constructor() {
        this.#field = 1;
        this.#field += 2;
        this.#field -= 3;
        this.#field /= 4;
        this.#field *= 5;
        this.#field **= 6;
        this.#field %= 7;
        this.#field <<= 8;
        this.#field >>= 9;
        this.#field >>>= 10;
        this.#field &= 11;
        this.#field |= 12;
        this.#field ^= 13;
        A.getInstance().#field = 1;
        A.getInstance().#field += 2;
        A.getInstance().#field -= 3;
        A.getInstance().#field /= 4;
        A.getInstance().#field *= 5;
        A.getInstance().#field **= 6;
        A.getInstance().#field %= 7;
        A.getInstance().#field <<= 8;
        A.getInstance().#field >>= 9;
        A.getInstance().#field >>>= 10;
        A.getInstance().#field &= 11;
        A.getInstance().#field |= 12;
        A.getInstance().#field ^= 13;
    }
    static getInstance() {
        return new A();
    }
}
`,
      [],
    );
  });
  test("privateNameFieldCallExpression", async () => {
    await expectPass(
      `
class A {
    #fieldFunc = function() { this.x = 10; };
    #fieldFunc2 = function(a, ...b) {};
    x = 1;
    test() {
        this.#fieldFunc();
        this.#fieldFunc?.();
        const func = this.#fieldFunc;
        func();
        new this.#fieldFunc();

        const arr = [ 1, 2 ];
        this.#fieldFunc2(0, ...arr, 3);
        const b = new this.#fieldFunc2(0, ...arr, 3);
        const str = this.#fieldFunc2\`head\${1}middle\${2}tail\`;
        this.getInstance().#fieldFunc2\`test\${1}and\${2}\`;
    }
    getInstance() { return new A(); }
}
`,
      [],
    );
  });
  test("privateNameFieldClassExpression", async () => {
    await expectPass(
      `
class B {
    #foo = class {
        constructor() {
            console.log("hello");
        }
        static test = 123;
    };
    #foo2 = class Foo {
        static otherClass = 123;
    };
}`,
      [],
    );
  });
  test("privateNameFieldDerivedClasses", async () => {
    await expectPass(
      `
class Base {
    #prop: number = 123;
    static method(x: Derived) {
        console.log(x.#prop);
    }
}
class Derived extends Base {
    static method(x: Derived) {
        console.log(x.#prop);
    }
}`,
      [],
    );
  });
  test("privateNameFieldDestructuredBinding", async () => {
    await expectPass(
      `
class A {
    #field = 1;
    otherObject = new A();
    testObject() {
        return { x: 10, y: 6 };
    }
    testArray() {
        return [10, 11];
    }
    constructor() {
        let y: number;
        ({ x: this.#field, y } = this.testObject());
        ([this.#field, y] = this.testArray());
        ({ a: this.#field, b: [this.#field] } = { a: 1, b: [2] });
        [this.#field, [this.#field]] = [1, [2]];
        ({ a: this.#field = 1, b: [this.#field = 1] } = { b: [] });
        [this.#field = 2] = [];
        [this.otherObject.#field = 2] = [];
    }
    static test(_a: A) {
        [_a.#field] = [2];
    }
}
`,
      [],
    );
  });
  test("privateNameFieldInitializer", async () => {
    await expectPass(
      `
class A {
    #field = 10;
    #uninitialized;
}
`,
      [],
    );
  });
  test("privateNameFieldParenthesisLeftAssignment", async () => {
    await expectPass(
      `
class Foo {
    #p: number;

    constructor(value: number) {
        this.#p = value;
    }

    t1(p: number) {
        (this.#p as number) = p;
    }

    t2(p: number) {
        (((this.#p as number))) = p;
    }

    t3(p: number) {
        (this.#p) = p;
    }

    t4(p: number) {
        (((this.#p))) = p;
    }
}
`,
      [],
    );
  });
  test("privateNameFieldsESNext", async () => {
    await expectPass(
      `
class C {
    a = 123;
    #a = 10;
    c = "hello";
    #b;
    method() {
        console.log(this.#a);
        this.#a = "hello";
        console.log(this.#b);
    }
    static #m = "test";
    static #x;
    static test() {
        console.log(this.#m);
        console.log(this.#x = "test");
    }
    #something = () => 1234;
}`,
      [],
    );
  });
  test("privateNameFieldUnaryMutation", async () => {
    await expectPass(
      `
class C {
    #test: number = 24;
    constructor() {
        this.#test++;
        this.#test--;
        ++this.#test;
        --this.#test;
        const a = this.#test++;
        const b = this.#test--;
        const c = ++this.#test;
        const d = --this.#test;
        for (this.#test = 0; this.#test < 10; ++this.#test) {}
        for (this.#test = 0; this.#test < 10; this.#test++) {}

        (this.#test)++;
        (this.#test)--;
        ++(this.#test);
        --(this.#test);
        const e = (this.#test)++;
        const f = (this.#test)--;
        const g = ++(this.#test);
        const h = --(this.#test);
        for (this.#test = 0; this.#test < 10; ++(this.#test)) {}
        for (this.#test = 0; this.#test < 10; (this.#test)++) {}
    }
    test() {
        this.getInstance().#test++;
        this.getInstance().#test--;
        ++this.getInstance().#test;
        --this.getInstance().#test;
        const a = this.getInstance().#test++;
        const b = this.getInstance().#test--;
        const c = ++this.getInstance().#test;
        const d = --this.getInstance().#test;
        for (this.getInstance().#test = 0; this.getInstance().#test < 10; ++this.getInstance().#test) {}
        for (this.getInstance().#test = 0; this.getInstance().#test < 10; this.getInstance().#test++) {}

        (this.getInstance().#test)++;
        (this.getInstance().#test)--;
        ++(this.getInstance().#test);
        --(this.getInstance().#test);
        const e = (this.getInstance().#test)++;
        const f = (this.getInstance().#test)--;
        const g = ++(this.getInstance().#test);
        const h = --(this.getInstance().#test);
        for (this.getInstance().#test = 0; this.getInstance().#test < 10; ++(this.getInstance().#test)) {}
        for (this.getInstance().#test = 0; this.getInstance().#test < 10; (this.getInstance().#test)++) {}
    }
    getInstance() { return new C(); }
}
`,
      [],
    );
  });
  test("privateNameHashCharName", async () => {
    await expectError(
      `
#

class C {
    #

    m() {
        this.#
    }
}
`,
      [],
    );
  });
  test("privateNameImplicitDeclaration", async () => {
    await expectPass(
      `
class C {
    constructor() {
        /** @type {string} */
        this.#x;
    }
}`,
      [],
    );
  });
  test("privateNameInInExpression", async () => {
    await expectError(
      `
class Foo {
    #field = 1;
    static #staticField = 2;
    #method() {}
    static #staticMethod() {}

    goodRhs(v: any) {
        const a = #field in v;

        const b = #field in v.p1.p2;

        const c = #field in (v as {});

        const d = #field in (v as Foo);

        const e = #field in (v as never);

        for (let f in #field in v as any) { /**/ } // unlikely but valid
    }
    badRhs(v: any) {
        const a = #field in (v as unknown); // Bad - RHS of in must be object type or any

        const b = #fiel in v; // Bad - typo in privateID

        const c = (#field) in v; // Bad - privateID is not an expression on its own

        for (#field in v) { /**/ } // Bad - 'in' not allowed

        for (let d in #field in v) { /**/ } // Bad - rhs of in should be a object/any
    }
    whitespace(v: any) {
        const a = v && /*0*/#field/*1*/
            /*2*/in/*3*/
                /*4*/v/*5*/
    }
    flow(u: unknown, n: never, fb: Foo | Bar, fs: FooSub, b: Bar, fsb: FooSub | Bar, fsfb: Foo | FooSub | Bar) {

        if (typeof u === 'object') {
            if (#field in n) {
                n; // good n is never
            }

            if (#field in u) {
                u; // good u is Foo
            } else {
                u; // good u is object | null
            }

            if (u !== null) {
                if (#field in u) {
                    u; // good u is Foo
                } else {
                    u; // good u is object
                }

                if (#method in u) {
                    u; // good u is Foo
                }

                if (#staticField in u) {
                    u; // good u is typeof Foo
                }

                if (#staticMethod in u) {
                    u; // good u is typeof Foo
                }
            }
        }

        if (#field in fb) {
            fb; // good fb is Foo
        } else {
            fb; // good fb is Bar
        }

        if (#field in fs) {
            fs; // good fs is FooSub
        } else {
            fs; // good fs is never
        }

        if (#field in b) {
            b; // good b is 'Bar & Foo'
        } else {
            b; // good b is Bar
        }

        if (#field in fsb) {
            fsb; // good fsb is FooSub
        } else {
            fsb; // good fsb is Bar
        }

        if (#field in fsfb) {
            fsfb; // good fsfb is 'Foo | FooSub'
        } else {
            fsfb; // good fsfb is Bar
        }

        class Nested {
            m(v: any) {
                if (#field in v) {
                    v; // good v is Foo
                }
            }
        }
    }
}

class FooSub extends Foo { subTypeOfFoo = true }
class Bar { notFoo = true }

function badSyntax(v: Foo) {
    return #field in v; // Bad - outside of class
}`,
      [],
    );
  });
  test("privateNameInInExpressionTransform", async () => {
    await expectError(
      `
class Foo {
    #field = 1;
    #method() {}
    static #staticField= 2;
    static #staticMethod() {}

    check(v: any) {
        #field in v; // expect Foo's 'field' WeakMap
        #method in v; // expect Foo's 'instances' WeakSet
        #staticField in v; // expect Foo's constructor
        #staticMethod in v; // expect Foo's constructor
    }
    precedence(v: any) {
        // '==' and '||' have lower precedence than 'in'
        // 'in'  naturally has same precedence as 'in'
        // '<<' has higher precedence than 'in'

        v == #field in v || v; // Good precedence: (v == (#field in v)) || v

        v << #field in v << v; // Good precedence (SyntaxError): (v << #field) in (v << v)

        v << #field in v == v; // Good precedence (SyntaxError): ((v << #field) in v) == v

        v == #field in v in v; // Good precedence: v == ((#field in v) in v)

        #field in v && #field in v; // Good precedence: (#field in v) && (#field in v)
    }
    invalidLHS(v: any) {
        'prop' in v = 10;
        #field in v = 10;
    }
}

class Bar {
    #field = 1;
    check(v: any) {
        #field in v; // expect Bar's 'field' WeakMap
    }
}

function syntaxError(v: Foo) {
    return #field in v; // expect \`return in v\` so runtime will have a syntax error
}

export { }
`,
      [],
    );
  });
  test("privateNameInInExpressionUnused", async () => {
    await expectPass(
      `
class Foo {
    #unused: undefined; // expect unused error
    #brand: undefined; // expect no error

    isFoo(v: any): v is Foo {
        // This should count as using/reading '#brand'
        return #brand in v;
    }
}`,
      [],
    );
  });
  test("privateNameInLhsReceiverExpression", async () => {
    await expectPass(
      `
class Test {
    #y = 123;
    static something(obj: { [key: string]: Test }) {
        obj[(new class { #x = 1; readonly s = "prop"; }).s].#y = 1;
        obj[(new class { #x = 1; readonly s = "prop"; }).s].#y += 1;
    }
}`,
      [],
    );
  });
  test("privateNameInObjectLiteral-1", async () => {
    await expectError(
      `const obj = {
    #foo: 1
};`,
      [],
    );
  });
  test("privateNameInObjectLiteral-2", async () => {
    await expectError(
      `const obj = {
    #foo() {

    }
};`,
      [],
    );
  });
  test("privateNameInObjectLiteral-3", async () => {
    await expectPass(
      `const obj = {
    get #foo() {
        return ""
    }
};`,
      [],
    );
  });
  test("privateNameJsBadAssignment", async () => {
    await expectPass(
      `
exports.#nope = 1;           // Error (outside class body)
function A() { }
A.prototype.#no = 2;         // Error (outside class body)

class B {}
B.#foo = 3;                  // Error (outside class body)

class C {
    #bar = 6;
    constructor () {
        this.#foo = 3;       // Error (undeclared)
    }
}`,
      [],
    );
  });
  test("privateNameJsBadDeclaration", async () => {
    await expectError(
      `
function A() { }
A.prototype = {
  #x: 1,         // Error
  #m() {},       // Error
  get #p() { return "" } // Error
}
class B { }
B.prototype = {
  #y: 2,         // Error
  #m() {},       // Error
  get #p() { return "" } // Error
}
class C {
  constructor() {
    this.#z = 3;
  }
}`,
      [],
    );
  });
  test("privateNameLateSuper", async () => {
    await expectPass(
      `class B {}
class A extends B {
    #x;
    constructor() {
        void 0;
        super();
    }
}`,
      [],
    );
  });
  test("privateNameLateSuperUseDefineForClassFields", async () => {
    await expectPass(
      `class B {}
class A extends B {
    #x;
    constructor() {
        void 0;
        super();
    }
}`,
      [],
    );
  });
  test("privateNameMethod", async () => {
    await expectPass(
      `
class A1 {
    #method(param: string): string {
        return "";
    }
    constructor(name: string) {
        this.#method("")
        this.#method(1) // Error
        this.#method()  // Error 

    }
}
`,
      [],
    );
  });
  test("privateNameMethodAccess", async () => {
    await expectPass(
      `
class A2 {
    #method() { return "" }
    constructor() {
        console.log(this.#method);
        let a: A2 = this;
        a.#method();
        function  foo (){
            a.#method();
        }
    }
}
new A2().#method(); // Error

function  foo (){
    new A2().#method(); // Error
}

class B2 {
    m() {
        new A2().#method();
    }
}
`,
      [],
    );
  });
  test("privateNameMethodAssignment", async () => {
    await expectPass(
      `
class A3 {
    #method() { };
    constructor(a: A3, b: any) {
        this.#method = () => {} // Error, not writable 
        a.#method = () => { }; // Error, not writable 
        b.#method =  () => { } //Error, not writable 
        ({ x: this.#method } = { x: () => {}}); //Error, not writable 
        let x = this.#method;
        b.#method++ //Error, not writable 
    }
}
`,
      [],
    );
  });
  test("privateNameMethodAsync", async () => {
    await expectPass(
      `
const C = class {
    async #bar() { return await Promise.resolve(42); }
    async foo() {
        const b = await this.#bar();
        return b + (this.#baz().next().value || 0) + ((await this.#qux().next()).value || 0);
    }
    *#baz() { yield 42; }
    async *#qux() {
        yield (await Promise.resolve(42));
    }
}

new C().foo().then(console.log);`,
      [],
    );
  });
  test("privateNameMethodCallExpression", async () => {
    await expectPass(
      `
class AA {
    #method() { this.x = 10; };
    #method2(a, ...b) {};
    x = 1;
    test() {
        this.#method();
        const func = this.#method;
        func();
        new this.#method();

        const arr = [ 1, 2 ];
        this.#method2(0, ...arr, 3);

        const b = new this.#method2(0, ...arr, 3); //Error 
        const str = this.#method2\`head\${1}middle\${2}tail\`;
        this.getInstance().#method2\`test\${1}and\${2}\`;

        this.getInstance().#method2(0, ...arr, 3); 
        const b2 = new (this.getInstance().#method2)(0, ...arr, 3); //Error 
        const str2 = this.getInstance().#method2\`head\${1}middle\${2}tail\`;
    }
    getInstance() { return new AA(); }
}
`,
      [],
    );
  });
  test("privateNameMethodClassExpression", async () => {
    await expectPass(
      `
const C = class {
    #field = this.#method();
    #method() { return 42; }
    static getInstance() { return new C(); }
    getField() { return this.#field };
}

console.log(C.getInstance().getField());
C.getInstance().#method; // Error
C.getInstance().#field; // Error`,
      [],
    );
  });
  test("privateNameMethodInStaticFieldInit", async () => {
    await expectPass(
      `
class C {
    static s = new C().#method();
    #method() { return 42; }
}

console.log(C.s);`,
      [],
    );
  });
  test("privateNameMethodsDerivedClasses", async () => {
    await expectPass(
      `
class Base {
    #prop(): number{ return  123; }
    static method(x: Derived) {
        console.log(x.#prop());
    }
}
class Derived extends Base {
    static method(x: Derived) {
        console.log(x.#prop());
    }
}`,
      [],
    );
  });
  test("privateNameNestedClassAccessorsShadowing", async () => {
    await expectPass(
      `
class Base {
    get #x() { return 1; };
    constructor() {
        class Derived {
            get #x() { return 1; };
            testBase(x: Base) {
                console.log(x.#x);
            }
            testDerived(x: Derived) {
                console.log(x.#x);
            }
        }
    }
}`,
      [],
    );
  });
  test("privateNameNestedClassFieldShadowing", async () => {
    await expectPass(
      `
class Base {
    #x;
    constructor() {
        class Derived {
            #x;
            testBase(x: Base) {
                console.log(x.#x);
            }
            testDerived(x: Derived) {
                console.log(x.#x);
            }
        }
    }
}`,
      [],
    );
  });
  test("privateNameNestedClassMethodShadowing", async () => {
    await expectPass(
      `
class Base {
    #x() { };
    constructor() {
        class Derived {
            #x() { };
            testBase(x: Base) {
                console.log(x.#x);
            }
            testDerived(x: Derived) {
                console.log(x.#x);
            }
        }
    }
}`,
      [],
    );
  });
  test("privateNameNestedClassNameConflict", async () => {
    await expectPass(
      `
class A {
    #foo: string;
    constructor() {
        class A {
            #foo: string;
        }
    }
}
`,
      [],
    );
  });
  test("privateNameNestedMethodAccess", async () => {
    await expectPass(
      `
class C {
    #foo = 42;
    #bar() { new C().#baz; }
    get #baz() { return 42; }

    m() {
        return class D {
            #bar() {}
            constructor() {
                new C().#foo;
                new C().#bar; // Error
                new C().#baz;
                new D().#bar;
            }

            n(x: any) {
                x.#foo;
                x.#bar;
                x.#unknown; // Error
            }
        }
    }
}`,
      [],
    );
  });
  test("privateNameNotAccessibleOutsideDefiningClass", async () => {
    await expectPass(
      `
class A {
    #foo: number = 3;
}

new A().#foo = 4;               // Error
`,
      [],
    );
  });
  test("privateNameNotAllowedOutsideClass", async () => {
    await expectError(
      `
const #foo = 3;
`,
      [],
    );
  });
  test("privateNameReadonly", async () => {
    await expectPass(
      `
const C = class {
    #bar() {}
    foo() {
        this.#bar = console.log("should log this then throw");
    }
}

console.log(new C().foo());`,
      [],
    );
  });
  test("privateNamesAndDecorators", async () => {
    await expectPass(
      `declare function dec<T>(target: T): T;

class A {
    @dec                // Error
    #foo = 1;
    @dec                // Error
    #bar(): void { }
}`,
      [],
    );
  });
  test("privateNamesAndFields", async () => {
    await expectPass(
      `
class A {
    #foo: number;
    constructor () {
        this.#foo = 3;
    }
}

class B extends A {
    #foo: string;
    constructor () {
        super();
        this.#foo = "some string";
    }
}
`,
      [],
    );
  });
  test("privateNamesAndGenericClasses-2", async () => {
    await expectPass(
      `
class C<T> {
    #foo: T;
    #bar(): T {
      return this.#foo;
    }
    constructor(t: T) {
      this.#foo = t;
      t = this.#bar();
    }
    set baz(t: T) {
      this.#foo = t;

    }
    get baz(): T {
      return this.#foo;
    }
}

let a = new C(3);
let b = new C("hello");

a.baz = 5                                 // OK
const x: number = a.baz                   // OK
a.#foo;                                   // Error
a = b;                                    // Error
b = a;                                    // Error
`,
      [],
    );
  });
  test("privateNamesAndIndexedAccess", async () => {
    await expectError(
      `
class C {
    foo = 3;
    #bar = 3;
    constructor () {
        const ok: C["foo"] = 3;
        // not supported yet, could support in future:
        const badForNow: C[#bar] = 3;   // Error
        // will never use this syntax, already taken:
        const badAlways: C["#bar"] = 3; // Error
    }
}
`,
      [],
    );
  });
  test("privateNamesAndkeyof", async () => {
    await expectPass(
      `
class A {
    #fooField = 3;
    #fooMethod() { };
    get #fooProp() { return 1; };
    set #fooProp(value: number) { };
    bar = 3;
    baz = 3;
}

// \`keyof A\` should not include '#foo*'
let k: keyof A = "bar"; // OK
k = "baz"; // OK

k = "#fooField"; // Error
k = "#fooMethod"; // Error
k = "#fooProp"; // Error

k = "fooField"; // Error
k = "fooMethod"; // Error
k = "fooProp"; // Error
`,
      [],
    );
  });
  test("privateNamesAndMethods", async () => {
    await expectPass(
      `
class A {
    #foo(a: number) {}
    async #bar(a: number) {}
    async *#baz(a: number) {
        return 3;
    }
    #_quux: number;
    get #quux (): number {
        return this.#_quux;
    }
    set #quux (val: number) {
        this.#_quux = val;
    }
    constructor () {
        this.#foo(30);
        this.#bar(30);
        this.#baz(30);
        this.#quux = this.#quux + 1;
        this.#quux++;
 }
}

class B extends A {
    #foo(a: string) {}
    constructor () {
        super();
        this.#foo("str");
    }
}`,
      [],
    );
  });
  test("privateNamesAndStaticFields", async () => {
    await expectPass(
      `
class A {
    static #foo: number;
    static #bar: number;
    constructor () {
        A.#foo = 3;
        B.#foo; // Error
        B.#bar; // Error
    }
}

class B extends A {
    static #foo: string;
    constructor () {
        super();
        B.#foo = "some string";
    }
}

// We currently filter out static private identifier fields in \`getUnmatchedProperties\`.
// We will need a more robust solution when we support static fields
const willErrorSomeDay: typeof A = class {}; // OK for now
`,
      [],
    );
  });
  test("privateNamesAndStaticMethods", async () => {
    await expectPass(
      `
class A {
    static #foo(a: number) {}
    static async #bar(a: number) {}
    static async *#baz(a: number) {
        return 3;
    }
    static #_quux: number;
    static get #quux (): number {
        return this.#_quux;
    }
    static set #quux (val: number) {
        this.#_quux = val;
    }
    constructor () {
        A.#foo(30);
        A.#bar(30);
        A.#bar(30);
        A.#quux = A.#quux + 1;
        A.#quux++;
 }
}

class B extends A {
    static #foo(a: string) {}
    constructor () {
        super();
        B.#foo("str");
    }
}
`,
      [],
    );
  });
  test("privateNamesAssertion", async () => {
    await expectError(
      `
class Foo {
    #p1: (v: any) => asserts v is string = (v) => {
        if (typeof v !== "string") {
            throw new Error();
        }
    }
    m1(v: unknown) {
        this.#p1(v);
        v;
    }
}

class Foo2 {
    #p1(v: any): asserts v is string {
        if (typeof v !== "string") {
            throw new Error();
        }
    }
    m1(v: unknown) {
        this.#p1(v);
        v;
    }
}
`,
      [],
    );
  });
  test("privateNamesConstructorChain-1", async () => {
    await expectPass(
      `
class Parent {
    #foo = 3;
    static #bar = 5;
    accessChildProps() {
        new Child().#foo; // OK (\`#foo\` was added when \`Parent\`'s constructor was called on \`child\`)
        Child.#bar;       // Error: not found
    }
}

class Child extends Parent {
    #foo = "foo";       // OK (Child's #foo does not conflict, as \`Parent\`'s \`#foo\` is not accessible)
    #bar = "bar";       // OK
}`,
      [],
    );
  });
  test("privateNamesConstructorChain-2", async () => {
    await expectPass(
      `
class Parent<T> {
    #foo = 3;
    static #bar = 5;
    accessChildProps() {
        new Child<string>().#foo; // OK (\`#foo\` was added when \`Parent\`'s constructor was called on \`child\`)
        Child.#bar;       // Error: not found
    }
}

class Child<T> extends Parent<T> {
    #foo = "foo";       // OK (Child's #foo does not conflict, as \`Parent\`'s \`#foo\` is not accessible)
    #bar = "bar";       // OK
}

new Parent<number>().accessChildProps();`,
      [],
    );
  });
  test("privateNameSetterExprReturnValue", async () => {
    await expectPass(
      `
class C {
    set #foo(a: number) {}
    bar() {
        let x = (this.#foo = 42 * 2);
        console.log(x); // 84
    }
}

new C().bar();`,
      [],
    );
  });
  test("privateNameSetterNoGetter", async () => {
    await expectPass(
      `
const C = class {
    set #x(x) {}
    m() {
        this.#x += 2; // Error
    }
}

console.log(new C().m());`,
      [],
    );
  });
  test("privateNamesIncompatibleModifiers", async () => {
    await expectError(
      `
class A {
    public #foo = 3;         // Error
    private #bar = 3;        // Error
    protected #baz = 3;      // Error
    readonly #qux = 3;       // OK
    declare #what: number;   // Error

    public #fooMethod() { return  3; }         // Error
    private #barMethod() { return  3; }        // Error
    protected #bazMethod() { return  3; }      // Error
    readonly #quxMethod() { return  3; }       // Error
    declare #whatMethod()                      // Error
    async #asyncMethod() { return 1; }         //OK
    *#genMethod() { return 1; }                //OK
    async *#asyncGenMethod() { return 1; }     //OK

    public get #fooProp() { return  3; }         // Error
    public set #fooProp(value: number) {  }      // Error
    private get #barProp() { return  3; }        // Error
    private set #barProp(value: number) {  }     // Error
    protected get #bazProp() { return  3; }      // Error
    protected set #bazProp(value: number) {  }   // Error
    readonly get #quxProp() { return  3; }       // Error
    readonly set #quxProp(value: number) {  }    // Error
    declare get #whatProp()                      // Error
    declare set #whatProp(value: number)         // Error
    async get #asyncProp() { return 1; }         // Error
    async set #asyncProp(value: number) { }      // Error
}

abstract class B {
    abstract #quux = 3;      // Error
}
`,
      [],
    );
  });
  test("privateNamesIncompatibleModifiersJs", async () => {
    await expectPass(
      `
class A {
    /**
     * @public
     */
    #a = 1;

    /**
     * @private
     */
    #b = 1;

    /**
     * @protected
     */
    #c = 1;

    /**
     * @public
     */
    #aMethod() { return 1; }

    /**
     * @private
     */
    #bMethod() { return 1; }

    /**
     * @protected
     */
    #cMethod() { return 1; }

    /**
     * @public
     */
    get #aProp() { return 1; }
    /**
     * @public
     */
    set #aProp(value) { }

    /**
     * @private
     */
    get #bProp() { return 1; }
    /**
     * @private
     */
    set #bProp(value) { }

    /**
    * @protected
    */
    get #cProp() { return 1; }
    /**
     * @protected
     */
    set #cProp(value) { }
}
`,
      [],
    );
  });
  test("privateNamesInGenericClasses", async () => {
    await expectPass(
      `
class C<T> {
    #foo: T;
    #method(): T { return this.#foo; }
    get #prop(): T { return this.#foo; }
    set #prop(value : T) { this.#foo = value; }
    
    bar(x: C<T>) { return x.#foo; }          // OK
    bar2(x: C<T>) { return x.#method(); }    // OK
    bar3(x: C<T>) { return x.#prop; }        // OK

    baz(x: C<number>) { return x.#foo; }     // OK
    baz2(x: C<number>) { return x.#method; } // OK
    baz3(x: C<number>) { return x.#prop; }   // OK

    quux(x: C<string>) { return x.#foo; }    // OK
    quux2(x: C<string>) { return x.#method; }// OK
    quux3(x: C<string>) { return x.#prop; }  // OK
}

declare let a: C<number>;
declare let b: C<string>;
a.#foo;                                   // Error
a.#method;                                // Error
a.#prop;                                  // Error
a = b;                                    // Error
b = a;                                    // Error
`,
      [],
    );
  });
  test("privateNamesInNestedClasses-1", async () => {
    await expectPass(
      `
class A {
   #foo = "A's #foo";
   #bar = "A's #bar";
   method () {
       class B {
           #foo = "B's #foo";
           bar (a: any) {
               a.#foo; // OK, no compile-time error, don't know what \`a\` is
           }
           baz (a: A) {
               a.#foo; // compile-time error, shadowed
           }
           quux (b: B) {
               b.#foo; // OK
           }
       }
       const a = new A();
       new B().bar(a);
       new B().baz(a);
       const b = new B();
       new B().quux(b);
   }
}

new A().method();`,
      [],
    );
  });
  test("privateNamesInNestedClasses-2", async () => {
    await expectPass(
      `
class A {
    static #x = 5;
    constructor () {
        class B {
            #x = 5;
            constructor() {
                class C {
                    constructor() {
                        A.#x // error
                    }
                }
            }
        }
    }
}
`,
      [],
    );
  });
  test("privateNamesInterfaceExtendingClass", async () => {
    await expectPass(
      `
class C {
    #prop;
    func(x: I) {
        x.#prop = 123;
    }
}
interface I extends C {}

function func(x: I) {
    x.#prop = 123;
}`,
      [],
    );
  });
  test("privateNamesNoDelete", async () => {
    await expectError(
      `
class A {
    #v = 1;
    constructor() {
        delete this.#v; // Error: The operand of a delete operator cannot be a private name.
    }
}
`,
      [],
    );
  });
  test("privateNamesNotAllowedAsParameters", async () => {
    await expectError(
      `
class A {
    setFoo(#foo: string) {}
}
`,
      [],
    );
  });
  test("privateNamesNotAllowedInVariableDeclarations", async () => {
    await expectError(
      `
const #foo = 3;`,
      [],
    );
  });
  test("privateNameStaticAccessors", async () => {
    await expectPass(
      `
class A1 {
    static get #prop() { return ""; }
    static set #prop(param: string) { }

    static get #roProp() { return ""; }

    constructor(name: string) {
        A1.#prop = "";
        A1.#roProp = ""; // Error
        console.log(A1.#prop);
        console.log(A1.#roProp);
    }
}
`,
      [],
    );
  });
  test("privateNameStaticAccessorsAccess", async () => {
    await expectPass(
      `export {}
class A2 {
    static get #prop() { return ""; }
    static set #prop(param: string) { }

    constructor() {
        console.log(A2.#prop);
        let a: typeof A2 = A2;
        a.#prop;
        function  foo (){
            a.#prop;
        }
    }
}

A2.#prop; // Error

function  foo (){
    A2.#prop; // Error
}

class B2 {
    m() {
        A2.#prop;
    }
}
`,
      [],
    );
  });
  test("privateNameStaticAccessorsCallExpression", async () => {
    await expectPass(
      `
class A {
    static get #fieldFunc() {  return function() { A.#x = 10; } }
    static get #fieldFunc2() { return  function(a, ...b) {}; }
    static #x = 1;
    static test() {
        this.#fieldFunc();
        const func = this.#fieldFunc;
        func();
        new this.#fieldFunc();

        const arr = [ 1, 2 ];
        this.#fieldFunc2(0, ...arr, 3);
        const b = new this.#fieldFunc2(0, ...arr, 3);
        const str = this.#fieldFunc2\`head\${1}middle\${2}tail\`;
        this.getClass().#fieldFunc2\`test\${1}and\${2}\`;
    }
    static getClass() { return A; }
}`,
      [],
    );
  });
  test("privateNameStaticAccessorssDerivedClasses", async () => {
    await expectPass(
      `
class Base {
    static get #prop(): number { return  123; }
    static method(x: typeof Derived) {
        console.log(x.#prop);
    }
}
class Derived extends Base {
    static method(x: typeof Derived) {
        console.log(x.#prop);
    }
}`,
      [],
    );
  });
  test("privateNameStaticAndStaticInitializer", async () => {
    await expectPass(
      `
class A {
  static #foo = 1;
  static #prop = 2;
}`,
      [],
    );
  });
  test("privateNameStaticEmitHelpers", async () => {
    await expectPass(
      `

export class S {
    static #a = 1;
    static #b() { this.#a = 42; }
    static get #c() { return S.#b(); }
}

// these are pre-TS4.3 versions of emit helpers, which only supported private instance fields
export declare function __classPrivateFieldGet<T extends object, V>(receiver: T, state: any): V;
export declare function __classPrivateFieldSet<T extends object, V>(receiver: T, state: any, value: V): V;`,
      [],
    );
  });
  test("privateNameStaticFieldAccess", async () => {
    await expectPass(
      `
class A {
    static #myField = "hello world";
    constructor() {
        console.log(A.#myField); //Ok
        console.log(this.#myField); //Error
    }
}
`,
      [],
    );
  });
  test("privateNameStaticFieldAssignment", async () => {
    await expectPass(
      `
class A {
    static #field = 0;
    constructor() {
        A.#field = 1;
        A.#field += 2;
        A.#field -= 3;
        A.#field /= 4;
        A.#field *= 5;
        A.#field **= 6;
        A.#field %= 7;
        A.#field <<= 8;
        A.#field >>= 9;
        A.#field >>>= 10;
        A.#field &= 11;
        A.#field |= 12;
        A.#field ^= 13;
        A.getClass().#field = 1;
        A.getClass().#field += 2;
        A.getClass().#field -= 3;
        A.getClass().#field /= 4;
        A.getClass().#field *= 5;
        A.getClass().#field **= 6;
        A.getClass().#field %= 7;
        A.getClass().#field <<= 8;
        A.getClass().#field >>= 9;
        A.getClass().#field >>>= 10;
        A.getClass().#field &= 11;
        A.getClass().#field |= 12;
        A.getClass().#field ^= 13;
    }
    static getClass() {
        return A;
    }
}
`,
      [],
    );
  });
  test("privateNameStaticFieldCallExpression", async () => {
    await expectPass(
      `
class A {
    static #fieldFunc = function () { this.x = 10; };
    static #fieldFunc2 = function (a, ...b) {};
    x = 1;
    test() {
        A.#fieldFunc();
        A.#fieldFunc?.();
        const func = A.#fieldFunc;
        func();
        new A.#fieldFunc();

        const arr = [ 1, 2 ];
        A.#fieldFunc2(0, ...arr, 3);
        const b = new A.#fieldFunc2(0, ...arr, 3);
        const str = A.#fieldFunc2\`head\${1}middle\${2}tail\`;
        this.getClass().#fieldFunc2\`test\${1}and\${2}\`;
    }
    getClass() { return A; }
}
`,
      [],
    );
  });
  test("privateNameStaticFieldClassExpression", async () => {
    await expectPass(
      `
class B {
    static #foo = class {
        constructor() {
            console.log("hello");
            new B.#foo2();
        }
        static test = 123;
        field = 10;
    };
    static #foo2 = class Foo {
        static otherClass = 123;
    };

    m() {
        console.log(B.#foo.test)
        B.#foo.test = 10;
        new B.#foo().field;
    }
}`,
      [],
    );
  });
  test("privateNameStaticFieldDerivedClasses", async () => {
    await expectPass(
      `
class Base {
    static #prop: number = 123;
    static method(x: Derived) {
        Derived.#derivedProp // error
        Base.#prop  = 10;
    }
}
class Derived extends Base {
    static #derivedProp: number = 10;
    static method(x: Derived) {
        Derived.#derivedProp
        Base.#prop  = 10; // error
    }
}`,
      [],
    );
  });
  test("privateNameStaticFieldDestructuredBinding", async () => {
    await expectPass(
      `
class A {
    static #field = 1;
    otherClass = A;
    testObject() {
        return { x: 10, y: 6 };
    }
    testArray() {
        return [10, 11];
    }
    constructor() {
        let y: number;
        ({ x: A.#field, y } = this.testObject());
        ([A.#field, y] = this.testArray());
        ({ a: A.#field, b: [A.#field] } = { a: 1, b: [2] });
        [A.#field, [A.#field]] = [1, [2]];
        ({ a: A.#field = 1, b: [A.#field = 1] } = { b: [] });
        [A.#field = 2] = [];
        [this.otherClass.#field = 2] = [];
    }
    static test(_a: typeof A) {
        [_a.#field] = [2];
    }
}
`,
      [],
    );
  });
  test("privateNameStaticFieldInitializer", async () => {
    await expectPass(
      `
class A {
    static #field = 10;
    static #uninitialized;
}
`,
      [],
    );
  });
  test("privateNameStaticFieldNoInitializer", async () => {
    await expectPass(
      `
const C = class {
    static #x;
}

class C2 {
    static #x;
}
`,
      [],
    );
  });
  test("privateNameStaticFieldUnaryMutation", async () => {
    await expectPass(
      `
class C {
    static #test: number = 24;
    constructor() {
        C.#test++;
        C.#test--;
        ++C.#test;
        --C.#test;
        const a = C.#test++;
        const b = C.#test--;
        const c = ++C.#test;
        const d = --C.#test;
        for (C.#test = 0; C.#test < 10; ++C.#test) {}
        for (C.#test = 0; C.#test < 10; C.#test++) {}
    }
    test() {
        this.getClass().#test++;
        this.getClass().#test--;
        ++this.getClass().#test;
        --this.getClass().#test;
        const a = this.getClass().#test++;
        const b = this.getClass().#test--;
        const c = ++this.getClass().#test;
        const d = --this.getClass().#test;
        for (this.getClass().#test = 0; this.getClass().#test < 10; ++this.getClass().#test) {}
        for (this.getClass().#test = 0; this.getClass().#test < 10; this.getClass().#test++) {}
    }
    getClass() { return C; }
}
`,
      [],
    );
  });
  test("privateNameStaticMethod", async () => {
    await expectPass(
      `
class A1 {
    static #method(param: string): string {
        return "";
    }
    constructor() {
        A1.#method("")
        A1.#method(1) // Error
        A1.#method()  // Error 

    }
}
`,
      [],
    );
  });
  test("privateNameStaticMethodAssignment", async () => {
    await expectPass(
      `
class A3 {
    static #method() { };
    constructor(a: typeof A3, b: any) {
        A3.#method = () => {} // Error, not writable 
        a.#method = () => { }; // Error, not writable 
        b.#method =  () => { } //Error, not writable 
        ({ x: A3.#method } = { x: () => {}}); //Error, not writable 
        let x = A3.#method;
        b.#method++ //Error, not writable 
    }
}
`,
      [],
    );
  });
  test("privateNameStaticMethodAsync", async () => {
    await expectError(
      `
const C = class {
    static async #bar() { return await Promise.resolve(42); }
    static async foo() {
        const b = await this.#bar();
        return b + (this.#baz().next().value || 0) + ((await this.#qux().next()).value || 0);
    }
    static *#baz() { yield 42; }
    static async *#qux() {
        yield (await Promise.resolve(42));
    }
    async static *#bazBad() { yield 42; }
}`,
      [],
    );
  });
  test("privateNameStaticMethodCallExpression", async () => {
    await expectPass(
      `
class AA {
    static #method() { this.x = 10; };
    static #method2(a, ...b) {};
    static x = 1;
    test() {
        AA.#method();
        const func = AA.#method;
        func();
        new AA.#method();

        const arr = [ 1, 2 ];
        AA.#method2(0, ...arr, 3);

        const b = new AA.#method2(0, ...arr, 3); //Error 
        const str = AA.#method2\`head\${1}middle\${2}tail\`;
        AA.getClass().#method2\`test\${1}and\${2}\`;

        AA.getClass().#method2(0, ...arr, 3); 
        const b2 = new (AA.getClass().#method2)(0, ...arr, 3); //Error 
        const str2 = AA.getClass().#method2\`head\${1}middle\${2}tail\`;
    }
    static getClass() { return AA; }
}
`,
      [],
    );
  });
  test("privateNameStaticMethodClassExpression", async () => {
    await expectPass(
      `
const C = class D {
    static #field = D.#method();
    static #method() { return 42; }
    static getClass() { return D; }
    static getField() { return C.#field };
}

console.log(C.getClass().getField());
C.getClass().#method; // Error
C.getClass().#field; // Error`,
      [],
    );
  });
  test("privateNameStaticMethodInStaticFieldInit", async () => {
    await expectPass(
      `
class C {
    static s = C.#method();
    static #method() { return 42; }
}

console.log(C.s);`,
      [],
    );
  });
  test("privateNameStaticsAndStaticMethods", async () => {
    await expectPass(
      `
class A {
    static #foo(a: number) {}
    static async #bar(a: number) {}
    static async *#baz(a: number) {
        return 3;
    }
    static #_quux: number;
    static get #quux (): number {
        return this.#_quux;
    }
    static set #quux (val: number) {
        this.#_quux = val;
    }
    constructor () {
        A.#foo(30);
        A.#bar(30);
        A.#bar(30);
        A.#quux = A.#quux + 1;
        A.#quux++;
 }
}

class B extends A {
    static #foo(a: string) {}
    constructor () {
        super();
        B.#foo("str");
    }
}
`,
      [],
    );
  });
  test("privateNamesUnique-1", async () => {
    await expectPass(
      `
class A {
    #foo: number;
}

class B {
    #foo: number;
}

const b: A = new B();     // Error: Property #foo is missing
`,
      [],
    );
  });
  test("privateNamesUnique-3", async () => {
    await expectPass(
      `
class A {
    #foo = 1;
    static #foo = true; // error (duplicate)
                        // because static and instance private names
                        // share the same lexical scope
                        // https://tc39.es/proposal-class-fields/#prod-ClassBody
}
class B {
    static #foo = true;
    test(x: B) {
        x.#foo; // error (#foo is a static property on B, not an instance property)
    }
}`,
      [],
    );
  });
  test("privateNamesUnique-4", async () => {
    await expectPass(
      `
class A1 { }
interface A2 extends A1 { }
declare const a: A2;

class C { #something: number }
const c: C = a;`,
      [],
    );
  });
  test("privateNamesUnique-5", async () => {
    await expectPass(
      `
// same as privateNamesUnique-1, but with an interface

class A {
    #foo: number;
}
interface A2 extends A { }

class B {
    #foo: number;
}

const b: A2 = new B();`,
      [],
    );
  });
  test("privateNamesUseBeforeDef", async () => {
    await expectPass(
      `
class A {
    #foo = this.#bar; // Error
    #bar = 3;
}

class A2 {
    #foo = this.#bar(); // No Error
    #bar() { return 3 };
}

class A3 {
    #foo = this.#bar; // No Error
    get #bar() { return 3 };
}

class B {
    #foo = this.#bar; // Error
    #bar = this.#foo;
}`,
      [],
    );
  });
  test("privateNameUncheckedJsOptionalChain", async () => {
    await expectPass(
      `
class C {
    #bar;
    constructor () {
        this?.#foo;
        this?.#bar;
    }
}`,
      [],
    );
  });
  test("privateNameUnused", async () => {
    await expectPass(
      `
export class A {
    #used = "used";
    #unused = "unused";
    constructor () {
        console.log(this.#used);
    }
}

export class A2 {
    #used() {  };
    #unused() { };
    constructor () {
        console.log(this.#used());
    }
}

export class A3 {
    get #used() { return 0 };
    set #used(value: number) {  };
    
    get #unused() { return 0 };
    set #unused(value: number) {  };
    constructor () {
        console.log(this.#used);
    }
}`,
      [],
    );
  });
  test("privateNameWhenNotUseDefineForClassFieldsInEsNext", async () => {
    await expectPass(
      `
class TestWithStatics {
    #prop = 0
    static dd = new TestWithStatics().#prop; // OK
    static ["X_ z_ zz"] = class Inner {
        #foo  = 10
        m() {
            new TestWithStatics().#prop // OK
        }
        static C = class InnerInner {
            m() {
                new TestWithStatics().#prop // OK
                new Inner().#foo; // OK
            }
        }

        static M(){
            return class {
                m() {
                    new TestWithStatics().#prop // OK
                    new Inner().#foo; // OK
                }
            }
        }
    }
}

class TestNonStatics {
    #prop = 0
    dd = new TestNonStatics().#prop; // OK
    ["X_ z_ zz"] = class Inner {
        #foo  = 10
        m() {
            new TestNonStatics().#prop // Ok
        }
        C = class InnerInner {
            m() {
                new TestNonStatics().#prop // Ok
                new Inner().#foo; // Ok
            }
        }

        static M(){
            return class {
                m() {
                    new TestNonStatics().#prop // OK
                    new Inner().#foo; // OK
                }
            }
        }
    }
}`,
      [],
    );
  });
  test("privateStaticNameShadowing", async () => {
    await expectPass(
      `
class X {
    static #f = X.#m();
    constructor() {
      X.#m();
    }
    static #m() {
      const X: any = {}; // shadow the class
      const _a: any = {}; // shadow the first generated var
      X.#m(); // Should check with X as the receiver with _b as the class constructor 
      return 1;
    }
  }
  `,
      [],
    );
  });
  test("privateWriteOnlyAccessorRead", async () => {
    await expectPass(
      `class Test {
  set #value(v: { foo: { bar: number } }) {}
  set #valueRest(v: number[]) {}
  set #valueOne(v: number) {}
  set #valueCompound(v: number) {}

  m() {
    const foo = { bar: 1 };
    console.log(this.#value); // error
    this.#value = { foo }; // ok
    this.#value = { foo }; // ok
    this.#value.foo = foo; // error

    ({ o: this.#value } = { o: { foo } }); //ok
    ({ ...this.#value } = { foo }); //ok

    ({ foo: this.#value.foo } = { foo }); //error
    ({
      foo: { ...this.#value.foo },
    } = { foo }); //error

    let r = { o: this.#value }; //error

    [this.#valueOne, ...this.#valueRest] = [1, 2, 3];
    let arr = [
        this.#valueOne,
        ...this.#valueRest
    ];

    this.#valueCompound += 3;
  }
}
new Test().m();
`,
      [],
    );
  });
  test("typeFromPrivatePropertyAssignment", async () => {
    await expectPass(
      `
type Foo = { foo?: string };

class C {
    #a?: Foo;
    #b?: Foo;

    m() {
        const a = this.#a || {};
        this.#b = this.#b || {};
    }
}`,
      [],
    );
  });
  test("typeFromPrivatePropertyAssignmentJs", async () => {
    await expectPass(
      `
class C {
    /** @type {{ foo?: string } | undefined } */
    #a;
    /** @type {{ foo?: string } | undefined } */
    #b;
    m() {
        const a = this.#a || {};
        this.#b = this.#b || {};
    }
}`,
      [],
    );
  });
  test("optionalMethodDeclarations", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/34952#issuecomment-552025027
class C {
    // ? should be removed in emit
    method?() {}
}`,
      [],
    );
  });
  test("mixinAbstractClasses.2", async () => {
    await expectPass(
      `
interface Mixin {
    mixinMethod(): void;
}

function Mixin<TBaseClass extends abstract new (...args: any) => any>(baseClass: TBaseClass): TBaseClass & (abstract new (...args: any) => Mixin) {
    // error expected: A mixin class that extends from a type variable containing an abstract construct signature must also be declared 'abstract'.
    class MixinClass extends baseClass implements Mixin {
        mixinMethod() {
        }
    }
    return MixinClass;
}

abstract class AbstractBase {
    abstract abstractBaseMethod(): void;
}

const MixedBase = Mixin(AbstractBase);

// error expected: Non-abstract class 'DerivedFromAbstract' does not implement inherited abstract member 'abstractBaseMethod' from class 'AbstractBase & Mixin'.
class DerivedFromAbstract extends MixedBase {
}

// error expected: Cannot create an instance of an abstract class.
new MixedBase();`,
      [],
    );
  });
  test("mixinAbstractClasses", async () => {
    await expectPass(
      `
interface Mixin {
    mixinMethod(): void;
}

function Mixin<TBaseClass extends abstract new (...args: any) => any>(baseClass: TBaseClass): TBaseClass & (abstract new (...args: any) => Mixin) {
    abstract class MixinClass extends baseClass implements Mixin {
        mixinMethod() {
        }
    }
    return MixinClass;
}

class ConcreteBase {
    baseMethod() {}
}

abstract class AbstractBase {
    abstract abstractBaseMethod(): void;
}

class DerivedFromConcrete extends Mixin(ConcreteBase) {
}

const wasConcrete = new DerivedFromConcrete();
wasConcrete.baseMethod();
wasConcrete.mixinMethod();

class DerivedFromAbstract extends Mixin(AbstractBase) {
    abstractBaseMethod() {}
}

const wasAbstract = new DerivedFromAbstract();
wasAbstract.abstractBaseMethod();
wasAbstract.mixinMethod();`,
      [],
    );
  });
  test("mixinAbstractClassesReturnTypeInference", async () => {
    await expectPass(
      `
interface Mixin1 {
    mixinMethod(): void;
}

abstract class AbstractBase {
    abstract abstractBaseMethod(): void;
}

function Mixin2<TBase extends abstract new (...args: any[]) => any>(baseClass: TBase) {
    // must be \`abstract\` because we cannot know *all* of the possible abstract members that need to be
    // implemented for this to be concrete.
    abstract class MixinClass extends baseClass implements Mixin1 {
        mixinMethod(): void {}
        static staticMixinMethod(): void {}
    }
    return MixinClass;
}

class DerivedFromAbstract2 extends Mixin2(AbstractBase) {
    abstractBaseMethod() {}
}
`,
      [],
    );
  });
  test("mixinAccessModifiers", async () => {
    await expectPass(
      `
type Constructable = new (...args: any[]) => object;

class Private {
	constructor (...args: any[]) {}
	private p: string;
}

class Private2 {
	constructor (...args: any[]) {}
	private p: string;
}

class Protected {
	constructor (...args: any[]) {}
	protected p: string;
	protected static s: string;
}

class Protected2 {
	constructor (...args: any[]) {}
	protected p: string;
	protected static s: string;
}

class Public {
	constructor (...args: any[]) {}
	public p: string;
	public static s: string;
}

class Public2 {
	constructor (...args: any[]) {}
	public p: string;
	public static s: string;
}

function f1(x: Private & Private2) {
	x.p;  // Error, private constituent makes property inaccessible
}

function f2(x: Private & Protected) {
	x.p;  // Error, private constituent makes property inaccessible
}

function f3(x: Private & Public) {
	x.p;  // Error, private constituent makes property inaccessible
}

function f4(x: Protected & Protected2) {
	x.p;  // Error, protected when all constituents are protected
}

function f5(x: Protected & Public) {
	x.p;  // Ok, public if any constituent is public
}

function f6(x: Public & Public2) {
	x.p;  // Ok, public if any constituent is public
}

declare function Mix<T, U>(c1: T, c2: U): T & U;

// Can't derive from type with inaccessible properties

class C1 extends Mix(Private, Private2) {}
class C2 extends Mix(Private, Protected) {}
class C3 extends Mix(Private, Public) {}

class C4 extends Mix(Protected, Protected2) {
	f(c4: C4, c5: C5, c6: C6) {
		c4.p;
		c5.p;
		c6.p;
	}
	static g() {
		C4.s;
		C5.s;
		C6.s
	}
}

class C5 extends Mix(Protected, Public) {
	f(c4: C4, c5: C5, c6: C6) {
		c4.p;  // Error, not in class deriving from Protected2
		c5.p;
		c6.p;
	}
	static g() {
		C4.s;  // Error, not in class deriving from Protected2
		C5.s;
		C6.s
	}
}

class C6 extends Mix(Public, Public2) {
	f(c4: C4, c5: C5, c6: C6) {
		c4.p;  // Error, not in class deriving from Protected2
		c5.p;
		c6.p;
	}
	static g() {
		C4.s;  // Error, not in class deriving from Protected2
		C5.s;
		C6.s
	}
}

class ProtectedGeneric<T> {
	private privateMethod() {}
	protected protectedMethod() {}
}

class ProtectedGeneric2<T> {
	private privateMethod() {}
	protected protectedMethod() {}
}

function f7(x: ProtectedGeneric<{}> & ProtectedGeneric<{}>) {
	x.privateMethod(); // Error, private constituent makes method inaccessible
	x.protectedMethod(); // Error, protected when all constituents are protected
}

function f8(x: ProtectedGeneric<{a: void;}> & ProtectedGeneric2<{a:void;b:void;}>) {
	x.privateMethod(); // Error, private constituent makes method inaccessible
	x.protectedMethod(); // Error, protected when all constituents are protected
}

function f9(x: ProtectedGeneric<{a: void;}> & ProtectedGeneric<{a:void;b:void;}>) {
	x.privateMethod(); // Error, private constituent makes method inaccessible
	x.protectedMethod(); // Error, protected when all constituents are protected
}`,
      [],
    );
  });
  test("mixinAccessors1", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/58790

function mixin<T extends { new (...args: any[]): {} }>(superclass: T) {
  return class extends superclass {
    get validationTarget(): HTMLElement {
      return document.createElement("input");
    }
  };
}

class BaseClass {
  get validationTarget(): HTMLElement {
    return document.createElement("div");
  }
}

class MyClass extends mixin(BaseClass) {
  get validationTarget(): HTMLElement {
    return document.createElement("select");
  }
}`,
      [],
    );
  });
  test("mixinAccessors2", async () => {
    await expectPass(
      `
function mixin<T extends { new (...args: any[]): {} }>(superclass: T) {
  return class extends superclass {
    accessor name = "";
  };
}

class BaseClass {
  accessor name = "";
}

class MyClass extends mixin(BaseClass) {
  accessor name = "";
}`,
      [],
    );
  });
  test("mixinAccessors3", async () => {
    await expectPass(
      `
function mixin<T extends { new (...args: any[]): {} }>(superclass: T) {
  return class extends superclass {
    get name() {
      return "";
    }
  };
}

class BaseClass {
  set name(v: string) {}
}

// error
class MyClass extends mixin(BaseClass) { 
  get name() {
    return "";
  }
}`,
      [],
    );
  });
  test("mixinAccessors4", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/44938

class A {
  constructor(...args: any[]) {}
  get myName(): string {
    return "A";
  }
}

function Mixin<T extends typeof A>(Super: T) {
  return class B extends Super {
    get myName(): string {
      return "B";
    }
  };
}

class C extends Mixin(A) {
  get myName(): string {
    return "C";
  }
}`,
      [],
    );
  });
  test("mixinAccessors5", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/61967

declare function basicMixin<T extends object, U extends object>(
  t: T,
  u: U,
): T & U;
  
declare class GetterA {
  constructor(...args: any[]);

  get inCompendium(): boolean;
}
  
declare class GetterB {
  constructor(...args: any[]);

  get inCompendium(): boolean;
}
  
declare class TestB extends basicMixin(GetterA, GetterB) {
  override get inCompendium(): boolean;
}
  `,
      [],
    );
  });
  test("mixinClassesAnnotated", async () => {
    await expectPass(
      `
type Constructor<T> = new(...args: any[]) => T;

class Base {
    constructor(public x: number, public y: number) {}
}

class Derived extends Base {
    constructor(x: number, y: number, public z: number) {
        super(x, y);
    }
}

interface Printable {
    print(): void;
}

const Printable = <T extends Constructor<Base>>(superClass: T): Constructor<Printable> & { message: string } & T =>
    class extends superClass {
        static message = "hello";
        print() {
            const output = this.x + "," + this.y;
        }
    }

interface Tagged {
    _tag: string;
}

function Tagged<T extends Constructor<{}>>(superClass: T): Constructor<Tagged> & T {
    class C extends superClass {
        _tag: string;
        constructor(...args: any[]) {
            super(...args);
            this._tag = "hello";
        }
    }
    return C;
}

const Thing1 = Tagged(Derived);
const Thing2 = Tagged(Printable(Derived));
Thing2.message;

function f1() {
    const thing = new Thing1(1, 2, 3);
    thing.x;
    thing._tag;
}

function f2() {
    const thing = new Thing2(1, 2, 3);
    thing.x;
    thing._tag;
    thing.print();
}

class Thing3 extends Thing2 {
    constructor(tag: string) {
        super(10, 20, 30);
        this._tag = tag;
    }
    test() {
        this.print();
    }
}`,
      [],
    );
  });
  test("mixinClassesAnonymous", async () => {
    await expectPass(
      `type Constructor<T> = new(...args: any[]) => T;

class Base {
    constructor(public x: number, public y: number) {}
}

class Derived extends Base {
    constructor(x: number, y: number, public z: number) {
        super(x, y);
    }
}

const Printable = <T extends Constructor<Base>>(superClass: T) => class extends superClass {
    static message = "hello";
    print() {
        const output = this.x + "," + this.y;
    }
}

function Tagged<T extends Constructor<{}>>(superClass: T) {
    class C extends superClass {
        _tag: string;
        constructor(...args: any[]) {
            super(...args);
            this._tag = "hello";
        }
    }
    return C;
}

const Thing1 = Tagged(Derived);
const Thing2 = Tagged(Printable(Derived));
Thing2.message;

function f1() {
    const thing = new Thing1(1, 2, 3);
    thing.x;
    thing._tag;
}

function f2() {
    const thing = new Thing2(1, 2, 3);
    thing.x;
    thing._tag;
    thing.print();
}

class Thing3 extends Thing2 {
    constructor(tag: string) {
        super(10, 20, 30);
        this._tag = tag;
    }
    test() {
        this.print();
    }
}

// Repro from #13805

const Timestamped = <CT extends Constructor<object>>(Base: CT) => {
    return class extends Base {
        timestamp = new Date();
    };
}`,
      [],
    );
  });
  test("mixinClassesMembers", async () => {
    await expectPass(
      `
declare class C1 {
    public a: number;
    protected b: number;
    private c: number;
    constructor(s: string);
    constructor(n: number);
}

declare class M1 {
    constructor(...args: any[]);
    p: number;
    static p: number;
}

declare class M2 {
    constructor(...args: any[]);
    f(): number;
    static f(): number;
}

declare const Mixed1: typeof M1 & typeof C1;
declare const Mixed2: typeof C1 & typeof M1;
declare const Mixed3: typeof M2 & typeof M1 & typeof C1;
declare const Mixed4: typeof C1 & typeof M1 & typeof M2;
declare const Mixed5: typeof M1 & typeof M2;

function f1() {
    let x1 = new Mixed1("hello");
    let x2 = new Mixed1(42);
    let x3 = new Mixed2("hello");
    let x4 = new Mixed2(42);
    let x5 = new Mixed3("hello");
    let x6 = new Mixed3(42);
    let x7 = new Mixed4("hello");
    let x8 = new Mixed4(42);
    let x9 = new Mixed5();
}

function f2() {
    let x = new Mixed1("hello");
    x.a;
    x.p;
    Mixed1.p;
}

function f3() {
    let x = new Mixed2("hello");
    x.a;
    x.p;
    Mixed2.p;
}

function f4() {
    let x = new Mixed3("hello");
    x.a;
    x.p;
    x.f();
    Mixed3.p;
    Mixed3.f();
}

function f5() {
    let x = new Mixed4("hello");
    x.a;
    x.p;
    x.f();
    Mixed4.p;
    Mixed4.f();
}

function f6() {
    let x = new Mixed5();
    x.p;
    x.f();
    Mixed5.p;
    Mixed5.f();
}

class C2 extends Mixed1 {
    constructor() {
        super("hello");
        this.a;
        this.b;
        this.p;
    }
}

class C3 extends Mixed3 {
    constructor() {
        super(42);
        this.a;
        this.b;
        this.p;
        this.f();
    }
    f() { return super.f(); }
}`,
      [],
    );
  });
  test("mixinWithBaseDependingOnSelfNoCrash1", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/60202

declare class Document<Parent> {}

declare class BaseItem extends Document<typeof Item> {}

declare function ClientDocumentMixin<
  BaseClass extends new (...args: any[]) => any,
>(Base: BaseClass): any;

declare class Item extends ClientDocumentMixin(BaseItem) {}

export {};`,
      [],
    );
  });
  test("nestedClassDeclaration", async () => {
    await expectError(
      `// nested classes are not allowed

class C {
    x: string;
    class C2 {
    }
}

function foo() {
    class C3 {
    }
}

var x = {
    class C4 {
    }
}
`,
      [],
    );
  });
  test("abstractProperty", async () => {
    await expectPass(
      `abstract class A {
    protected abstract x: string;
    public foo() {
        console.log(this.x);
    }
}

class B extends A {
    protected x = 'B.x';
}

class C extends A {
    protected get x() { return 'C.x' };
}`,
      [],
    );
  });
  test("abstractPropertyInitializer", async () => {
    await expectPass(
      `abstract class C {
    abstract prop = 1
}`,
      [],
    );
  });
  test("accessibilityModifiers", async () => {
    await expectPass(
      `
// No errors
class C {
    private static privateProperty;
    private static privateMethod() { }
    private static get privateGetter() { return 0; }
    private static set privateSetter(a: number) { }

    protected static protectedProperty;
    protected static protectedMethod() { }
    protected static get protectedGetter() { return 0; }
    protected static set protectedSetter(a: number) { }

    public static publicProperty;
    public static publicMethod() { }
    public static get publicGetter() { return 0; }
    public static set publicSetter(a: number) { }
}

// Errors, accessibility modifiers must precede static
class D {
    static private privateProperty;
    static private privateMethod() { }
    static private get privateGetter() { return 0; }
    static private set privateSetter(a: number) { }

    static protected protectedProperty;
    static protected protectedMethod() { }
    static protected get protectedGetter() { return 0; }
    static protected set protectedSetter(a: number) { }

    static public publicProperty;
    static public publicMethod() { }
    static public get publicGetter() { return 0; }
    static public set publicSetter(a: number) { }
}

// Errors, multiple accessibility modifier
class E {
    private public protected property;
    public protected method() { }
    private protected get getter() { return 0; }
    public public set setter(a: number) { }
}
`,
      [],
    );
  });
  test("accessorsOverrideMethod", async () => {
    await expectPass(
      `class A {
    m() { }
}
class B extends A {
    get m() { return () => 1 }
}`,
      [],
    );
  });
  test("accessorsOverrideProperty", async () => {
    await expectPass(
      `class A {
    p = 'yep'
}
class B extends A {
    get p() { return 'oh no' } // error
}
class C {
   p = 101
}
class D extends C {
     _secret = 11
    get p() { return this._secret } // error
    set p(value) { this._secret = value } // error
}`,
      [],
    );
  });
  test("accessorsOverrideProperty10", async () => {
    await expectPass(
      `
class A {
  x = 1;
}
class B extends A {}
class C extends B {
  get x() {
    return 2;
  }
}`,
      [],
    );
  });
  test("accessorsOverrideProperty2", async () => {
    await expectPass(
      `class Base {
  x = 1;
}

class Derived extends Base {
  get x() { return 2; } // should be an error
  set x(value) { console.log(\`x was set to \${value}\`); }
}

const obj = new Derived(); // nothing printed
console.log(obj.x); // number`,
      [],
    );
  });
  test("accessorsOverrideProperty3", async () => {
    await expectPass(
      `declare class Animal {
    sound: string
}
class Lion extends Animal {
    _sound = 'grrr'
    get sound() { return this._sound } // error here
    set sound(val) { this._sound = val }
}`,
      [],
    );
  });
  test("accessorsOverrideProperty4", async () => {
    await expectPass(
      `declare class Animal {
    sound: string;
}
class Lion extends Animal {
    _sound = 'roar'
    get sound(): string { return this._sound }
    set sound(val: string) { this._sound = val }
}`,
      [],
    );
  });
  test("accessorsOverrideProperty5", async () => {
    await expectPass(
      `interface I {
    p: number
}
interface B extends I { }
class B { }
class C extends B {
    get p() { return 1 }
    set p(value) { }
}`,
      [],
    );
  });
  test("accessorsOverrideProperty6", async () => {
    await expectPass(
      `class A {
    p = 'yep'
}
class B extends A {
    get p() { return 'oh no' } // error
}
class C {
   p = 101
}
class D extends C {
     _secret = 11
    get p() { return this._secret } // error
    set p(value) { this._secret = value } // error
}`,
      [],
    );
  });
  test("accessorsOverrideProperty7", async () => {
    await expectPass(
      `abstract class A {
    abstract p = 'yep'
}
class B extends A {
    get p() { return 'oh no' } // error
}`,
      [],
    );
  });
  test("accessorsOverrideProperty8", async () => {
    await expectPass(
      `type Types = 'boolean' | 'unknown' | 'string';

type Properties<T extends { [key: string]: Types }> = {
    readonly [key in keyof T]: T[key] extends 'boolean' ? boolean : T[key] extends 'string' ? string : unknown
}

type AnyCtor<P extends object> = new (...a: any[]) => P

declare function classWithProperties<T extends { [key: string]: Types }, P extends object>(properties: T, klass: AnyCtor<P>): {
    new(): P & Properties<T>;
    prototype: P & Properties<T>
};

const Base = classWithProperties({
    get x() { return 'boolean' as const },
    y: 'string',
}, class Base {
});

class MyClass extends Base {
    get x() {
        return false;
    }
    get y() {
        return 'hi'
    }
}

const mine = new MyClass();
const value = mine.x;`,
      [],
    );
  });
  test("accessorsOverrideProperty9", async () => {
    await expectPass(
      `// #41347, based on microsoft/rushstack

// Mixin utilities
export type Constructor<T = {}> = new (...args: any[]) => T;
export type PropertiesOf<T> = { [K in keyof T]: T[K] };

interface IApiItemConstructor extends Constructor<ApiItem>, PropertiesOf<typeof ApiItem> {}

// Base class
class ApiItem {
  public get members(): ReadonlyArray<ApiItem> {
    return [];
  }
}

// Normal subclass
class ApiEnumMember extends ApiItem {
}

// Mixin base class
interface ApiItemContainerMixin extends ApiItem {
  readonly members: ReadonlyArray<ApiItem>;
}

function ApiItemContainerMixin<TBaseClass extends IApiItemConstructor>(
  baseClass: TBaseClass
): TBaseClass & (new (...args: any[]) => ApiItemContainerMixin) {
  abstract class MixedClass extends baseClass implements ApiItemContainerMixin {
    public constructor(...args: any[]) {
      super(...args);
    }

    public get members(): ReadonlyArray<ApiItem> {
      return [];
    }
  }

  return MixedClass;
}

// Subclass inheriting from mixin
export class ApiEnum extends ApiItemContainerMixin(ApiItem) {
  // This worked prior to TypeScript 4.0:
  public get members(): ReadonlyArray<ApiEnumMember> {
    return [];
  }
}`,
      [],
    );
  });
  test("assignParameterPropertyToPropertyDeclarationES2022", async () => {
    await expectPass(
      `class C {
    qux = this.bar // should error
    bar = this.foo // should error
    quiz = this.bar // ok
    quench = this.m1() // ok
    quanch = this.m3() // should error
    m1() {
        this.foo // ok
    }
    m3 = function() { }
    constructor(public foo: string) {}
    quim = this.baz // should error
    baz = this.foo; // should error
    quid = this.baz // ok
    m2() {
        this.foo // ok
    }
}

class D extends C {
    quill = this.foo // ok
}

class E {
    bar = () => this.foo1 + this.foo2; // both ok
    foo1 = '';
    constructor(public foo2: string) {}
}

class F {
    Inner = class extends F {
        p2 = this.p1
    }
    p1 = 0
}
class G {
    Inner = class extends G {
        p2 = this.p1
    }
    constructor(public p1: number) {}
}
class H {
    constructor(public p1: C) {}

    public p2 = () => {
        return this.p1.foo;
    }

    public p3 = () => this.p1.foo;
}`,
      [],
    );
  });
  test("assignParameterPropertyToPropertyDeclarationESNext", async () => {
    await expectPass(
      `class C {
    qux = this.bar // should error
    bar = this.foo // should error
    quiz = this.bar // ok
    quench = this.m1() // ok
    quanch = this.m3() // should error
    m1() {
        this.foo // ok
    }
    m3 = function() { }
    constructor(public foo: string) {}
    quim = this.baz // should error
    baz = this.foo; // should error
    quid = this.baz // ok
    m2() {
        this.foo // ok
    }
}

class D extends C {
    quill = this.foo // ok
}

class E {
    bar = () => this.foo1 + this.foo2; // both ok
    foo1 = '';
    constructor(public foo2: string) {}
}

class F {
    Inner = class extends F {
        p2 = this.p1
    }
    p1 = 0
}
class G {
    Inner = class extends G {
        p2 = this.p1
    }
    constructor(public p1: number) {}
}
class H {
    constructor(public p1: C) {}

    public p2 = () => {
        return this.p1.foo;
    }

    public p3 = () => this.p1.foo;
}`,
      [],
    );
  });
  test("autoAccessor1", async () => {
    await expectPass(
      `
class C1 {
    accessor a: any;
    accessor b = 1;
    static accessor c: any;
    static accessor d = 2;
}
`,
      [],
    );
  });
  test("autoAccessor10", async () => {
    await expectPass(
      `
class C1 {
    accessor a0 = 1;
}

class C2 {
    #a1_accessor_storage = 1;
    accessor a1 = 2;
}

class C3 {
    static #a2_accessor_storage = 1;
    static {
        class C3_Inner {
            accessor a2 = 2;
            static {
                #a2_accessor_storage in C3;
            }
        }
    }
}

class C4_1 {
    static accessor a3 = 1;
}

class C4_2 {
    static accessor a3 = 1;
}`,
      [],
    );
  });
  test("autoAccessor11", async () => {
    await expectPass(
      `
class C {
    accessor
    a

    static accessor
    b

    static
    accessor
    c

    accessor accessor
    d;
}
`,
      [],
    );
  });
  test("autoAccessor2", async () => {
    await expectPass(
      `
class C1 {
    accessor #a: any;
    accessor #b = 1;
    static accessor #c: any;
    static accessor #d = 2;

    constructor() {
        this.#a = 3;
        this.#b = 4;
    }

    static {
        this.#c = 5;
        this.#d = 6;
    }
}
`,
      [],
    );
  });
  test("autoAccessor3", async () => {
    await expectPass(
      `
class C1 {
    accessor "w": any;
    accessor "x" = 1;
    static accessor "y": any;
    static accessor "z" = 2;
}
`,
      [],
    );
  });
  test("autoAccessor4", async () => {
    await expectPass(
      `
class C1 {
    accessor 0: any;
    accessor 1 = 1;
    static accessor 2: any;
    static accessor 3 = 2;
}
`,
      [],
    );
  });
  test("autoAccessor5", async () => {
    await expectPass(
      `
class C1 {
    accessor ["w"]: any;
    accessor ["x"] = 1;
    static accessor ["y"]: any;
    static accessor ["z"] = 2;
}

declare var f: any;
class C2 {
    accessor [f()] = 1;
}`,
      [],
    );
  });
  test("autoAccessor6", async () => {
    await expectPass(
      `
class C1 {
    accessor a: any;
}

class C2 extends C1 {
    a = 1;
}

class C3 extends C1 {
    get a() { return super.a; }
}
`,
      [],
    );
  });
  test("autoAccessor7", async () => {
    await expectPass(
      `
abstract class C1 {
    abstract accessor a: any;
}

class C2 extends C1 {
    accessor a = 1;
}

class C3 extends C1 {
    get a() { return 1; }
}
`,
      [],
    );
  });
  test("autoAccessor8", async () => {
    await expectPass(
      `
class C1 {
    accessor a: any;
    static accessor b: any;
}

declare class C2 {
    accessor a: any;
    static accessor b: any;
}

function f() {
    class C3 {
        accessor a: any;
        static accessor b: any;
    }
    return C3;
}
`,
      [],
    );
  });
  test("autoAccessor9", async () => {
    await expectPass(
      `
// Auto-accessors do not use Set semantics themselves, so do not need to be transformed if there are no other
// initializers that need to be transformed:
class C1 {
    accessor x = 1;
}

// If there are other field initializers to transform, we must transform auto-accessors so that we can preserve
// initialization order:
class C2 {
    x = 1;
    accessor y = 2;
    z = 3;
}

// Private field initializers also do not use Set semantics, so they do not force an auto-accessor transformation:
class C3 {
    #x = 1;
    accessor y = 2;
}

// However, we still need to hoist private field initializers to the constructor if we need to preserve initialization
// order:
class C4 {
    x = 1;
    #y = 2;
    z = 3;
}

class C5 {
    #x = 1;
    accessor y = 2;
    z = 3;
}

// Static accessors aren't affected:
class C6 {
    static accessor x = 1;
}

// Static accessors aren't affected:
class C7 {
    static x = 1;
    static accessor y = 2;
    static z = 3;
}
`,
      [],
    );
  });
  test("autoAccessorAllowedModifiers", async () => {
    await expectPass(
      `
abstract class C1 {
    accessor a: any;
    public accessor b: any;
    private accessor c: any;
    protected accessor d: any;
    abstract accessor e: any;
    static accessor f: any;
    public static accessor g: any;
    private static accessor h: any;
    protected static accessor i: any;
    accessor #j: any;
    accessor "k": any;
    accessor 108: any;
    accessor ["m"]: any;
    accessor n!: number;
}

class C2 extends C1 {
    override accessor e: any;
    static override accessor i: any;
}

declare class C3 {
    accessor a: any;
}

`,
      [],
    );
  });
  test("autoAccessorExperimentalDecorators", async () => {
    await expectError(
      `
declare var dec: (target: any, key: PropertyKey, desc: PropertyDescriptor) => void;

class C1 {
    @dec
    accessor a: any;

    @dec
    static accessor b: any;
}

class C2 {
    @dec
    accessor #a: any;

    @dec
    static accessor #b: any;
}
`,
      [],
    );
  });
  test("autoAccessorNoUseDefineForClassFields", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/51528
class C1 {
    static accessor x = 0;
}

class C2 {
    static accessor #x = 0;
}

class C3 {
    static accessor #x = 0;
    accessor #y = 0;
}

class C3 {
    accessor x = 0;
}

class C4 {
    accessor #x = 0;
}

class C5 {
    x = 0;
    accessor #x = 1;
}

class C6 {
    accessor #x = 0;
    x = 1;
}
`,
      [],
    );
  });
  test("canFollowGetSetKeyword", async () => {
    await expectError(
      `class A {
    get
    *x() {}
}
class B {
    set
    *x() {}
}
const c = {
    get
    *x() {}
};
const d = {
    set
    *x() {}
};`,
      [],
    );
  });
  test("constructorParameterShadowsOuterScopes", async () => {
    await expectPass(
      `// Initializer expressions for instance member variables are evaluated in the scope of the class constructor 
// body but are not permitted to reference parameters or local variables of the constructor.
// This effectively means that entities from outer scopes by the same name as a constructor parameter or 
// local variable are inaccessible in initializer expressions for instance member variables

var x = 1;
class C {
    b = x; // error, evaluated in scope of constructor, cannot reference x
    constructor(x: string) {
        x = 2; // error, x is string
    }    
}

var y = 1;
class D {
    b = y; // error, evaluated in scope of constructor, cannot reference y
    constructor(x: string) {
        var y = "";
    }
}`,
      [],
    );
  });
  test("constructorParameterShadowsOuterScopes2", async () => {
    await expectPass(
      `

// With useDefineForClassFields: true and ESNext target, initializer
// expressions for property declarations are evaluated in the scope of
// the class body and are permitted to reference parameters or local
// variables of the constructor. This is different from classic
// Typescript behaviour, with useDefineForClassFields: false. There,
// initialisers of property declarations are evaluated in the scope of
// the constructor body.

// Note that when class fields are accepted in the ECMAScript
// standard, the target will become that year's ES20xx

var x = 1;
class C {
    b = x; // ok
    constructor(x: string) {
    }
}

var y = 1;
class D {
    b = y; // ok
    constructor(x: string) {
        var y = "";
    }
}

class E {
    b = z; // not ok
    constructor(z: string) {
    }
}
`,
      [],
    );
  });
  test("defineProperty", async () => {
    await expectPass(
      `var x: "p" = "p"
class A {
    a = this.y
    b
    public c;
    ["computed"] = 13
    ;[x] = 14
    m() { }
    constructor(public readonly y: number) { }
    z = this.y
    declare notEmitted;
}
class B {
    public a;
}
class C extends B {
    declare public a;
    z = this.ka
    constructor(public ka: number) {
        super()
    }
    ki = this.ka
}`,
      [],
    );
  });
  test("derivedUninitializedPropertyDeclaration", async () => {
    await expectPass(
      `class A {
    property = 'x';
    m() { return 1 }
}
class B extends A {
    property: any; // error
}
class BD extends A {
    declare property: any; // ok because it's implicitly initialised
}
class BDBang extends A {
    declare property!: any; // ! is not allowed, this is an ambient declaration
}
class BOther extends A {
    declare m() { return 2 } // not allowed on methods
    declare nonce: any; // ok, even though it's not in the base
    declare property = 'y' // initialiser not allowed with declare
}
class U {
    declare nonce: any; // ok, even though there's no base
}

class C {
    p: string;
}
class D extends C {
    p: 'hi'; // error
}
class DD extends C {
    declare p: 'bye'; // ok
}


declare class E {
    p1: string
    p2: string
}
class F extends E {
    p1!: 'z'
    declare p2: 'alpha'
}

class G extends E {
    p1: 'z'
    constructor() {
        super()
        this.p1 = 'z'
    }
}

abstract class H extends E {
    abstract p1: 'a' | 'b' | 'c'
    declare abstract p2: 'a' | 'b' | 'c'
}

interface I {
    q: number
}
interface J extends I { }
class J {
    r = 5
}
class K extends J {
    q!: 1 | 2 | 3 // ok, extends a property from an interface
    r!: 4 | 5 // error, from class
}

// #35327
class L {
    a: any;
    constructor(arg: any) {
        this.a = arg;
    }
}
class M extends L {
    declare a: number;
    constructor(arg: number) {
        super(arg);
        console.log(this.a);  // should be OK, M.a is ambient
    }
}`,
      [],
    );
  });
  test("initializationOrdering1", async () => {
    await expectPass(
      `
class Helper {
    create(): boolean {
        return true
    }
}

export class Broken {
    constructor(readonly facade: Helper) {
        console.log(this.bug)
    }
    bug = this.facade.create()

}

new Broken(new Helper)`,
      [],
    );
  });
  test("initializerReferencingConstructorLocals", async () => {
    await expectPass(
      `// Initializer expressions for instance member variables are evaluated in the scope of the class constructor body but are not permitted to reference parameters or local variables of the constructor. 

class C {
    a = z; // error
    b: typeof z; // error
    c = this.z; // error
    d: typeof this.z; // error
    constructor(x) {
        z = 1;
    }
}

class D<T> {
    a = z; // error
    b: typeof z; // error
    c = this.z; // error
    d: typeof this.z; // error
    constructor(x: T) {
        z = 1;
    }
}`,
      [],
    );
  });
  test("initializerReferencingConstructorParameters", async () => {
    await expectPass(
      `// Initializer expressions for instance member variables are evaluated in the scope of the class constructor body but are not permitted to reference parameters or local variables of the constructor. 

class C {
    a = x; // error
    b: typeof x; // error
    constructor(x) { }
}

class D {
    a = x; // error
    b: typeof x; // error
    constructor(public x) { }
}

class E {
    a = this.x; // ok
    b: typeof this.x; // ok
    constructor(public x) { }
}

class F<T> {
    a = this.x; // ok
    b = x; // error
    constructor(public x: T) { }
}`,
      [],
    );
  });
  test("instanceMemberInitialization", async () => {
    await expectPass(
      `class C {
    x = 1;
}

var c = new C();
c.x = 3;
var c2 = new C();
var r = c.x === c2.x;

// #31792



class MyMap<K, V> {
    constructor(private readonly Map_: { new<K, V>(): any }) {}
    private readonly store = new this.Map_<K, V>();
}`,
      [],
    );
  });
  test("instanceMemberWithComputedPropertyName", async () => {
    await expectPass(
      `// https://github.com/microsoft/TypeScript/issues/30953
"use strict";
const x = 1;
class C {
    [x] = true;
    constructor() {
        const { a, b } = { a: 1, b: 2 };
    }
}`,
      [],
    );
  });
  test("instanceMemberWithComputedPropertyName2", async () => {
    await expectPass(
      `// https://github.com/microsoft/TypeScript/issues/33857
"use strict";
const x = 1;
class C {
    [x]: string;
}
`,
      [],
    );
  });
  test("accessorsAreNotContextuallyTyped", async () => {
    await expectPass(
      `// accessors are not contextually typed

class C {
    set x(v: (a: string) => string) {
    }

    get x() {
        return (x: string) => "";
    }
}

var c: C;
var r = c.x(''); // string`,
      [],
    );
  });
  test("accessorWithES5", async () => {
    await expectPass(
      `
class C {
    get x() {
        return 1;
    }
}

class D {
    set x(v) {
    }
}

var x = {
    get a() { return 1 }
}

var y = {
    set b(v) { }
}`,
      [],
    );
  });
  test("accessorWithMismatchedAccessibilityModifiers", async () => {
    await expectPass(
      `
class C {
    get x() {
        return 1;
    }
    private set x(v) {
    }
}

class D {
    protected get x() {
        return 1;
    }
    private set x(v) {
    }
}

class E {
    protected set x(v) {
    }
    get x() {
        return 1;
    }
}

class F {
    protected static set x(v) {
    }
    static get x() {
        return 1;
    }
}`,
      [],
    );
  });
  test("ambientAccessors", async () => {
    await expectPass(
      `// ok to use accessors in ambient class in ES3
declare class C {
    static get a(): string;
    static set a(value: string);

    private static get b(): string;
    private static set b(foo: string);

    get x(): string;
    set x(value: string);

    private get y(): string;
    private set y(foo: string);
}`,
      [],
    );
  });
  test("typeOfThisInAccessor", async () => {
    await expectPass(
      `class C {
    get x() {
        var r = this; // C
        return 1;
    }

    static get y() {
        var r2 = this; // typeof C
        return 1;
    }
}

class D<T> {
    a: T;
    get x() {
        var r = this; // D<T>
        return 1;
    }

    static get y() {
        var r2 = this; // typeof D
        return 1;
    }
}

var x = {
    get a() {
        var r3 = this; // any
        return 1;
    }
}`,
      [],
    );
  });
  test("derivedTypeAccessesHiddenBaseCallViaSuperPropertyAccess", async () => {
    await expectPass(
      `class Base {
    foo(x: { a: number }): { a: number } {
        return null;
    }
}

class Derived extends Base {
    foo(x: { a: number; b: number }): { a: number; b: number } {
        return null;
    }

    bar() {
        var r = super.foo({ a: 1 }); // { a: number }
        var r2 = super.foo({ a: 1, b: 2 }); // { a: number }
        var r3 = this.foo({ a: 1, b: 2 }); // { a: number; b: number; }
    }
}`,
      [],
    );
  });
  test("instanceMemberAssignsToClassPrototype", async () => {
    await expectPass(
      `class C {
    foo() {
        C.prototype.foo = () => { }
    }

    bar(x: number): number {
        C.prototype.bar = () => { } // error
        C.prototype.bar = (x) => x; // ok
        C.prototype.bar = (x: number) => 1; // ok
        return 1;
    }
}`,
      [],
    );
  });
  test("memberFunctionOverloadMixingStaticAndInstance", async () => {
    await expectPass(
      `class C {
    foo();
    static foo(); // error
}

class D {
    static foo();
    foo(); // error    
}

class E<T> {
    foo(x: T);
    static foo(x: number); // error
}

class F<T> {
    static foo(x: number);
    foo(x: T); // error    
}`,
      [],
    );
  });
  test("memberFunctionsWithPrivateOverloads", async () => {
    await expectPass(
      `class C {
    private foo(x: number);
    private foo(x: number, y: string);
    private foo(x: any, y?: any) { }

    private bar(x: 'hi');
    private bar(x: string);
    private bar(x: number, y: string);
    private bar(x: any, y?: any) { }

    private static foo(x: number);
    private static foo(x: number, y: string);
    private static foo(x: any, y?: any) { }

    private static bar(x: 'hi');
    private static bar(x: string);
    private static bar(x: number, y: string);
    private static bar(x: any, y?: any) { }
}

class D<T> {
    private foo(x: number);
    private foo(x: T, y: T);
    private foo(x: any, y?: any) { }

    private bar(x: 'hi');
    private bar(x: string);
    private bar(x: T, y: T);
    private bar(x: any, y?: any) { }

    private static foo(x: number);
    private static foo(x: number, y: number);
    private static foo(x: any, y?: any) { }

    private static bar(x: 'hi');
    private static bar(x: string);
    private static bar(x: number, y: number);
    private static bar(x: any, y?: any) { }

}

declare var c: C;
var r = c.foo(1); // error

declare var d: D<number>;
var r2 = d.foo(2); // error

var r3 = C.foo(1); // error
var r4 = D.bar(''); // error`,
      [],
    );
  });
  test("memberFunctionsWithPublicOverloads", async () => {
    await expectPass(
      `class C {
    public foo(x: number);
    public foo(x: number, y: string);
    public foo(x: any, y?: any) { }

    public bar(x: 'hi');
    public bar(x: string);
    public bar(x: number, y: string);
    public bar(x: any, y?: any) { }

    public static foo(x: number);
    public static foo(x: number, y: string);
    public static foo(x: any, y?: any) { }

    public static bar(x: 'hi');
    public static bar(x: string);
    public static bar(x: number, y: string);
    public static bar(x: any, y?: any) { }
}

class D<T> {
    public foo(x: number);
    public foo(x: T, y: T);
    public foo(x: any, y?: any) { }

    public bar(x: 'hi');
    public bar(x: string);
    public bar(x: T, y: T);
    public bar(x: any, y?: any) { }

    public static foo(x: number);
    public static foo(x: number, y: string);
    public static foo(x: any, y?: any) { }

    public static bar(x: 'hi');
    public static bar(x: string);
    public static bar(x: number, y: string);
    public static bar(x: any, y?: any) { }

}`,
      [],
    );
  });
  test("memberFunctionsWithPublicPrivateOverloads", async () => {
    await expectPass(
      `class C {
    private foo(x: number);
    public foo(x: number, y: string); // error
    private foo(x: any, y?: any) { }

    private bar(x: 'hi');
    public bar(x: string); // error
    private bar(x: number, y: string);
    private bar(x: any, y?: any) { }

    private static foo(x: number);
    public static foo(x: number, y: string); // error
    private static foo(x: any, y?: any) { }

    protected baz(x: string); // error
    protected baz(x: number, y: string); // error
    private baz(x: any, y?: any) { }

    private static bar(x: 'hi');
    public static bar(x: string); // error
    private static bar(x: number, y: string);
    private static bar(x: any, y?: any) { }

    protected static baz(x: 'hi');
    public static baz(x: string); // error
    protected static baz(x: number, y: string);
    protected static baz(x: any, y?: any) { }
}

class D<T> {
    private foo(x: number); 
    public foo(x: T, y: T); // error
    private foo(x: any, y?: any) { }

    private bar(x: 'hi');
    public bar(x: string); // error
    private bar(x: T, y: T);
    private bar(x: any, y?: any) { }

    private baz(x: string); 
    protected baz(x: number, y: string); // error
    private baz(x: any, y?: any) { }

    private static foo(x: number);
    public static foo(x: number, y: string); // error
    private static foo(x: any, y?: any) { }

    private static bar(x: 'hi');
    public static bar(x: string); // error
    private static bar(x: number, y: string);
    private static bar(x: any, y?: any) { }

    public static baz(x: string); // error
    protected static baz(x: number, y: string);
    protected static baz(x: any, y?: any) { }
}

declare var c: C;
var r = c.foo(1); // error

declare var d: D<number>;
var r2 = d.foo(2); // error`,
      [],
    );
  });
  test("staticFactory1", async () => {
    await expectPass(
      `class Base {
    foo() { return 1; }
    static create() {
        return new this();
    }
}

class Derived extends Base {
    foo() { return 2; }
}
var d = Derived.create(); 

d.foo();  `,
      [],
    );
  });
  test("staticMemberAssignsToConstructorFunctionMembers", async () => {
    await expectPass(
      `class C {
    static foo() {
        C.foo = () => { }
    }

    static bar(x: number): number {
        C.bar = () => { } // error
        C.bar = (x) => x; // ok
        C.bar = (x: number) => 1; // ok
        return 1;
    }
}`,
      [],
    );
  });
  test("typeOfThisInMemberFunctions", async () => {
    await expectPass(
      `class C {
    foo() {
        var r = this;
    }

    static bar() {
        var r2 = this;
    }
}

class D<T> {
    x: T;
    foo() {
        var r = this;
    }

    static bar() {
        var r2 = this;
    }
}

class E<T extends Date> {
    x: T;
    foo() {
        var r = this;
    }

    static bar() {
        var r2 = this;
    }
}`,
      [],
    );
  });
  test("optionalMethod", async () => {
    await expectPass(
      `class Base {
    method?() { }
}`,
      [],
    );
  });
  test("optionalProperty", async () => {
    await expectPass(
      `class C {
    prop?;
}`,
      [],
    );
  });
  test("overrideInterfaceProperty", async () => {
    await expectPass(
      `interface Mup<K, V> {
    readonly size: number;
}
interface MupConstructor {
    new(): Mup<any, any>;
    new<K, V>(entries?: readonly (readonly [K, V])[] | null): Mup<K, V>;
    readonly prototype: Mup<any, any>;
}
declare var Mup: MupConstructor;

class Sizz extends Mup {
    // ok, because Mup is an interface
    get size() { return 0 }
}
class Kasizz extends Mup {
    size = -1
}`,
      [],
    );
  });
  test("propertyAndAccessorWithSameName", async () => {
    await expectPass(
      `class C {
    x: number;
    get x() { // error
        return 1;
    }
}

class D {
    x: number;
    set x(v) { } // error
}

class E {
    private x: number;
    get x() { // error
        return 1;
    }
    set x(v) { }
}`,
      [],
    );
  });
  test("propertyAndFunctionWithSameName", async () => {
    await expectPass(
      `class C {
    x: number;
    x() { // error
        return 1;
    }
}

class D {
    x: number;
    x(v) { } // error
}`,
      [],
    );
  });
  test("propertyNamedConstructor", async () => {
    await expectError(
      `class X1 {
  "constructor" = 3; // Error
}

class X2 {
  ["constructor"] = 3;
}`,
      [],
    );
  });
  test("propertyNamedPrototype", async () => {
    await expectError(
      `class C {
    prototype: number; // ok
    static prototype: C; // error
}`,
      [],
    );
  });
  test("propertyOverridesAccessors", async () => {
    await expectPass(
      `class A {
    get p() { return 'oh no' }
}
class B extends A {
    p = 'yep' // error
}
class C {
    _secret = 11
    get p() { return this._secret }
    set p(value) { this._secret = value }
}
class D extends C {
    p = 101 // error
}`,
      [],
    );
  });
  test("propertyOverridesAccessors2", async () => {
    await expectPass(
      `class Base {
  get x() { return 2; }
  set x(value) { console.log(\`x was set to \${value}\`); }
}

class Derived extends Base {
  x = 1;
}

const obj = new Derived(); // prints 'x was set to 1'
console.log(obj.x); // 2`,
      [],
    );
  });
  test("propertyOverridesAccessors3", async () => {
    await expectPass(
      `class Animal {
    _sound = 'rustling noise in the bushes'

    get sound() { return this._sound }
    set sound(val) {
      this._sound = val;
      /* some important code here, perhaps tracking known sounds, etc */
    }

    makeSound() {
        console.log(this._sound)
    }
}

const a = new Animal
a.makeSound() // 'rustling noise in the bushes'

class Lion extends Animal {
    sound = 'RAWR!' // error here
}

const lion = new Lion
lion.makeSound() // with [[Define]]: Expected "RAWR!" but got "rustling noise in the bushes"`,
      [],
    );
  });
  test("propertyOverridesAccessors4", async () => {
    await expectPass(
      `declare class Animal {
    get sound(): string
    set sound(val: string)
}
class Lion extends Animal {
    sound = 'RAWR!' // error here
}`,
      [],
    );
  });
  test("propertyOverridesAccessors5", async () => {
    await expectPass(
      `class A {
    get p() { return 'oh no' }
}
class B extends A {
    constructor(public p: string) {
        super()
    }
}`,
      [],
    );
  });
  test("propertyOverridesAccessors6", async () => {
    await expectPass(
      `
class A {
  get x() {
    return 2;
  }
}
class B extends A {}
class C extends B {
  x = 1;
}`,
      [],
    );
  });
  test("propertyOverridesMethod", async () => {
    await expectPass(
      `class A {
    m() { }
}
class B extends A {
    m = () => 1
}`,
      [],
    );
  });
  test("redeclaredProperty", async () => {
    await expectPass(
      `class Base {
  b = 1;
}

class Derived extends Base {
  b;
  d = this.b;

  constructor() {
    super();
    this.b = 2;
  }
}`,
      [],
    );
  });
  test("redefinedPararameterProperty", async () => {
    await expectPass(
      `class Base {
    a = 1;
  }
  
  class Derived extends Base {
    b = this.a /*undefined*/;
  
    constructor(public a: number) {
        super();
    }
  }
  `,
      [],
    );
  });
  test("staticAndNonStaticPropertiesSameName", async () => {
    await expectPass(
      `class C {
    x: number;
    static x: number;

    f() { }
    static f() { }
}`,
      [],
    );
  });
  test("staticAutoAccessors", async () => {
    await expectPass(
      `// https://github.com/microsoft/TypeScript/issues/53752

class A {
    // uses class reference
    static accessor x = 1;

    // uses 'this'
    accessor y = 2;
}

`,
      [],
    );
  });
  test("staticAutoAccessorsWithDecorators", async () => {
    await expectPass(
      `// https://github.com/microsoft/TypeScript/issues/53752

class A {
    // uses class reference
    @((t, c) => {})
    static accessor x = 1;

    // uses 'this'
    @((t, c) => {})
    accessor y = 2;
}
`,
      [],
    );
  });
  test("staticMemberInitialization", async () => {
    await expectPass(
      `class C {
    static x = 1;
}

var c = new C();
var r = C.x;`,
      [],
    );
  });
  test("staticPropertyAndFunctionWithSameName", async () => {
    await expectPass(
      `class C {
    static f: number;
    f: number;
}

class D {
    static f: number;
    f() { }
}`,
      [],
    );
  });
  test("staticPropertyNameConflicts", async () => {
    await expectError(
      `
const FunctionPropertyNames = {
    name: 'name',
    length: 'length',
    prototype: 'prototype',
    caller: 'caller',
    arguments: 'arguments',
} as const;

// name
class StaticName {
    static name: number; // error without useDefineForClassFields
    name: string; // ok
}

class StaticName2 {
    static [FunctionPropertyNames.name]: number; // error without useDefineForClassFields
    [FunctionPropertyNames.name]: number; // ok
}

class StaticNameFn {
    static name() {} // error without useDefineForClassFields
    name() {} // ok
}

class StaticNameFn2 {
    static [FunctionPropertyNames.name]() {} // error without useDefineForClassFields
    [FunctionPropertyNames.name]() {} // ok
}

// length
class StaticLength {
    static length: number; // error without useDefineForClassFields
    length: string; // ok
}

class StaticLength2 {
    static [FunctionPropertyNames.length]: number; // error without useDefineForClassFields
    [FunctionPropertyNames.length]: number; // ok
}

class StaticLengthFn {
    static length() {} // error without useDefineForClassFields
    length() {} // ok
}

class StaticLengthFn2 {
    static [FunctionPropertyNames.length]() {} // error without useDefineForClassFields
    [FunctionPropertyNames.length]() {} // ok
}

// prototype
class StaticPrototype {
    static prototype: number; // always an error
    prototype: string; // ok
}

class StaticPrototype2 {
    static [FunctionPropertyNames.prototype]: number; // always an error
    [FunctionPropertyNames.prototype]: string; // ok
}

class StaticPrototypeFn {
    static prototype() {} // always an error
    prototype() {} // ok
}

class StaticPrototypeFn2 {
    static [FunctionPropertyNames.prototype]() {} // always an error
    [FunctionPropertyNames.prototype]() {} // ok
}

// caller
class StaticCaller {
    static caller: number; // error without useDefineForClassFields
    caller: string; // ok
}

class StaticCaller2 {
    static [FunctionPropertyNames.caller]: number; // error without useDefineForClassFields
    [FunctionPropertyNames.caller]: string; // ok
}

class StaticCallerFn {
    static caller() {} // error without useDefineForClassFields
    caller() {} // ok
}

class StaticCallerFn2 {
    static [FunctionPropertyNames.caller]() {} // error without useDefineForClassFields
    [FunctionPropertyNames.caller]() {} // ok
}

// arguments
class StaticArguments {
    static arguments: number; // error without useDefineForClassFields
    arguments: string; // ok
}

class StaticArguments2 {
    static [FunctionPropertyNames.arguments]: number; // error without useDefineForClassFields
    [FunctionPropertyNames.arguments]: string; // ok
}

class StaticArgumentsFn {
    static arguments() {} // error without useDefineForClassFields
    arguments() {} // ok
}

class StaticArgumentsFn2 {
    static [FunctionPropertyNames.arguments]() {} // error without useDefineForClassFields
    [FunctionPropertyNames.arguments]() {} // ok
}


// === Static properties on anonymous classes ===

// name
var StaticName_Anonymous = class {
    static name: number; // error without useDefineForClassFields
    name: string; // ok
}

var StaticName_Anonymous2 = class {
    static [FunctionPropertyNames.name]: number; // error without useDefineForClassFields
    [FunctionPropertyNames.name]: string; // ok
}

var StaticNameFn_Anonymous = class {
    static name() {} // error without useDefineForClassFields
    name() {} // ok
}

var StaticNameFn_Anonymous2 = class {
    static [FunctionPropertyNames.name]() {} // error without useDefineForClassFields
    [FunctionPropertyNames.name]() {} // ok
}

// length
var StaticLength_Anonymous = class {
    static length: number; // error without useDefineForClassFields
    length: string; // ok
}

var StaticLength_Anonymous2 = class {
    static [FunctionPropertyNames.length]: number; // error without useDefineForClassFields
    [FunctionPropertyNames.length]: string; // ok
}

var StaticLengthFn_Anonymous = class {
    static length() {} // error without useDefineForClassFields
    length() {} // ok
}

var StaticLengthFn_Anonymous2 = class {
    static [FunctionPropertyNames.length]() {} // error without useDefineForClassFields
    [FunctionPropertyNames.length]() {} // ok
}

// prototype
var StaticPrototype_Anonymous = class {
    static prototype: number; // always an error
    prototype: string; // ok
}

var StaticPrototype_Anonymous2 = class {
    static [FunctionPropertyNames.prototype]: number; // always an error
    [FunctionPropertyNames.prototype]: string; // ok
}

var StaticPrototypeFn_Anonymous = class {
    static prototype() {} // always an error
    prototype() {} // ok
}

var StaticPrototypeFn_Anonymous2 = class {
    static [FunctionPropertyNames.prototype]() {} // always an error
    [FunctionPropertyNames.prototype]() {} // ok
}

// caller
var StaticCaller_Anonymous = class {
    static caller: number; // error without useDefineForClassFields
    caller: string; // ok
}

var StaticCaller_Anonymous2 = class {
    static [FunctionPropertyNames.caller]: number; // error without useDefineForClassFields
    [FunctionPropertyNames.caller]: string; // ok
}

var StaticCallerFn_Anonymous = class {
    static caller() {} // error without useDefineForClassFields
    caller() {} // ok
}

var StaticCallerFn_Anonymous2 = class {
    static [FunctionPropertyNames.caller]() {} // error without useDefineForClassFields
    [FunctionPropertyNames.caller]() {} // ok
}

// arguments
var StaticArguments_Anonymous = class {
    static arguments: number; // error without useDefineForClassFields
    arguments: string; // ok
}

var StaticArguments_Anonymous2 = class {
    static [FunctionPropertyNames.arguments]: number; // error without useDefineForClassFields
    [FunctionPropertyNames.arguments]: string; // ok
}

var StaticArgumentsFn_Anonymous = class {
    static arguments() {} // error without useDefineForClassFields
    arguments() {} // ok
}

var StaticArgumentsFn_Anonymous2 = class {
    static [FunctionPropertyNames.arguments]() {} // error without useDefineForClassFields
    [FunctionPropertyNames.arguments]() {} // ok
}


// === Static properties on default exported classes ===

// name
namespace TestOnDefaultExportedClass_1 {
    class StaticName {
        static name: number; // error without useDefineForClassFields
        name: string; // ok
    }
}

export class ExportedStaticName {
    static [FunctionPropertyNames.name]: number; // error without useDefineForClassFields
    [FunctionPropertyNames.name]: string; // ok
}

namespace TestOnDefaultExportedClass_2 {
    class StaticNameFn {
        static name() {} // error without useDefineForClassFields
        name() {} // ok
    }
}

export class ExportedStaticNameFn {
    static [FunctionPropertyNames.name]() {} // error without useDefineForClassFields
    [FunctionPropertyNames.name]() {} // ok
}

// length
namespace TestOnDefaultExportedClass_3 {
    export default class StaticLength {
        static length: number; // error without useDefineForClassFields
        length: string; // ok
    }
}

export class ExportedStaticLength {
    static [FunctionPropertyNames.length]: number; // error without useDefineForClassFields
    [FunctionPropertyNames.length]: string; // ok
}

namespace TestOnDefaultExportedClass_4 {
    export default class StaticLengthFn {
        static length() {} // error without useDefineForClassFields
        length() {} // ok
    }
}

export class ExportedStaticLengthFn {
    static [FunctionPropertyNames.length]() {} // error without useDefineForClassFields
    [FunctionPropertyNames.length]() {} // ok
}

// prototype
namespace TestOnDefaultExportedClass_5 {
    export default class StaticPrototype {
        static prototype: number; // always an error
        prototype: string; // ok
    }
}

export class ExportedStaticPrototype {
    static [FunctionPropertyNames.prototype]: number; // always an error
    [FunctionPropertyNames.prototype]: string; // ok
}

namespace TestOnDefaultExportedClass_6 {
    export default class StaticPrototypeFn {
        static prototype() {} // always an error
        prototype() {} // ok
    }
}

export class ExportedStaticPrototypeFn {
    static [FunctionPropertyNames.prototype]() {} // always an error
    [FunctionPropertyNames.prototype]() {} // ok
}

// caller
namespace TestOnDefaultExportedClass_7 {
    export default class StaticCaller {
        static caller: number; // error without useDefineForClassFields
        caller: string; // ok
    }
}

export class ExportedStaticCaller {
    static [FunctionPropertyNames.caller]: number; // error without useDefineForClassFields
    [FunctionPropertyNames.caller]: string; // ok
}

namespace TestOnDefaultExportedClass_8 {
    export default class StaticCallerFn {
        static caller() {} // error without useDefineForClassFields
        caller() {} // ok
    }
}

export class ExportedStaticCallerFn {
    static [FunctionPropertyNames.caller]() {} // error without useDefineForClassFields
    [FunctionPropertyNames.caller]() {} // ok
}

// arguments
namespace TestOnDefaultExportedClass_9 {
    export default class StaticArguments {
        static arguments: number; // error without useDefineForClassFields
        arguments: string; // ok
    }
}

export class ExportedStaticArguments {
    static [FunctionPropertyNames.arguments]: number; // error without useDefineForClassFields
    [FunctionPropertyNames.arguments]: string; // ok
}

namespace TestOnDefaultExportedClass_10 {
    export default class StaticArgumentsFn {
        static arguments() {} // error without useDefineForClassFields
        arguments() {} // ok
    }
}

export class ExportedStaticArgumentsFn {
    static [FunctionPropertyNames.arguments]() {} // error without useDefineForClassFields
    [FunctionPropertyNames.arguments]() {} // ok
}`,
      [],
    );
  });
  test("staticPropertyNameConflictsInAmbientContext", async () => {
    await expectError(
      `
// name
declare class StaticName {
    static name: number; // ok
    name: string; // ok
}

declare class StaticNameFn {
    static name(): string; // ok
    name(): string; // ok
}

// length
declare class StaticLength {
    static length: number; // ok
    length: string; // ok
}

declare class StaticLengthFn {
    static length(): number; // ok
    length(): number; // ok
}

// prototype
declare class StaticPrototype {
    static prototype: number; // ok
    prototype: string; // ok
}

declare class StaticPrototypeFn {
    static prototype: any; // ok
    prototype(): any; // ok
}

// caller
declare class StaticCaller {
    static caller: number; // ok
    caller: string; // ok
}

declare class StaticCallerFn {
    static caller(): any; // ok
    caller(): any; // ok
}

// arguments
declare class StaticArguments {
    static arguments: number; // ok
    arguments: string; // ok
}

declare class StaticArgumentsFn {
    static arguments(): any; // ok
    arguments(): any; // ok
}`,
      [],
    );
  });
  test("strictPropertyInitialization", async () => {
    await expectPass(
      `
// Properties with non-undefined types require initialization

class C1 {
    a: number;  // Error
    b: number | undefined;
    c: number | null;  // Error
    d?: number;
    #f: number; //Error
    #g: number | undefined;
    #h: number | null; //Error
    #i?: number;
}

// No strict initialization checks in ambient contexts

declare class C2 {
    a: number;
    b: number | undefined;
    c: number | null;
    d?: number;
    
    #f: number;
    #g: number | undefined;
    #h: number | null;
    #i?: number;
}

// No strict initialization checks for static members

class C3 {
    static a: number;
    static b: number | undefined;
    static c: number | null;
    static d?: number;
}

// Initializer satisfies strict initialization check

class C4 {
    a = 0;
    b: number = 0;
    c: string = "abc";
    #d = 0
    #e: number = 0
    #f: string= "abc"
}

// Assignment in constructor satisfies strict initialization check

class C5 {
    a: number;
    #b: number;
    constructor() {
        this.a = 0;
        this.#b = 0;
    }
}

// All code paths must contain assignment

class C6 {
    a: number;  // Error
    #b: number
    constructor(cond: boolean) {
        if (cond) {
            return;
        }
        this.a = 0;
        this.#b = 0;
    }
}

class C7 {
    a: number;
    #b: number;
    constructor(cond: boolean) {
        if (cond) {
            this.a = 1;
            this.#b = 1;
            return;
        }
        this.a = 0;
        this.#b = 1;
    }
}

// Properties with string literal names aren't checked

class C8 {
    a: number;  // Error
    "b": number;
    0: number;
}

// No strict initialization checks for abstract members

abstract class C9 {
    abstract a: number;
    abstract b: number | undefined;
    abstract c: number | null;
    abstract d?: number;
}

// Properties with non-undefined types must be assigned before they can be accessed
// within their constructor

class C10 {
    a: number;
    b: number;
    c?: number;
    #d: number;
    constructor() {
        let x = this.a;  // Error
        this.a = this.b;  // Error
        this.b = this.#d //Error
        this.b = x;
        this.#d = x;
        let y = this.c;
    }
}

// Property is considered initialized by type any even though value could be undefined

declare function someValue(): any;

class C11 {
    a: number;
    #b: number;
    constructor() {
        this.a = someValue();
        this.#b = someValue();
    }
}

const a = 'a';
const b = Symbol();

class C12 {
    [a]: number;
    [b]: number;
    ['c']: number;

    constructor() {
        this[a] = 1;
        this[b] = 1;
        this['c'] = 1;
    }
}

enum E {
    A = "A",
    B = "B"
}
class C13 {
    [E.A]: number;
    constructor() {
        this[E.A] = 1;
    }
}
`,
      [],
    );
  });
  test("thisInInstanceMemberInitializer", async () => {
    await expectPass(
      `class C {
    x = this;
}

class D<T> {
    x = this;
    y: T;
}`,
      [],
    );
  });
  test("thisPropertyOverridesAccessors", async () => {
    await expectPass(
      `class Foo {
    get p() { return 1 }
    set p(value) { }
}

class Bar extends Foo {
    constructor() {
        super()
        this.p = 2
    }
}
`,
      [],
    );
  });
  test("twoAccessorsWithSameName", async () => {
    await expectPass(
      `class C {
    get x() { return 1; }
    get x() { return 1; } // error
}

class D {
    set x(v) {  }
    set x(v) {  } // error
}

class E {
    get x() {
        return 1;
    }
    set x(v) { }
}

var x = {
    get x() {
        return 1;
    },

    // error
    get x() {
        return 1;
    }
}

var y = {
    get x() {
        return 1;
    },
    set x(v) { }
}`,
      [],
    );
  });
  test("twoAccessorsWithSameName2", async () => {
    await expectPass(
      `class C {
    static get x() { return 1; }
    static get x() { return 1; } // error
}

class D {
    static set x(v) {  }
    static set x(v) {  } // error
}

class E {
    static get x() {
        return 1;
    }
    static set x(v) { }
}`,
      [],
    );
  });
  test("staticIndexSignature1", async () => {
    await expectPass(
      `class C {
    static [s: string]: number;
    static [s: number]: 42
}

C["foo"] = 1
C.bar = 2;
const foo = C["foo"]
C[42] = 42
C[2] = 2;
const bar = C[42] `,
      [],
    );
  });
  test("staticIndexSignature2", async () => {
    await expectPass(
      `class C {
    static readonly [s: string]: number;
    static readonly [s: number]: 42
}

C["foo"] = 1
C.bar = 2;
const foo = C["foo"]
C[42] = 42
C[2] = 2;
const bar = C[42] `,
      [],
    );
  });
  test("staticIndexSignature3", async () => {
    await expectPass(
      `
class B {
    static readonly [s: string]: number;
    static readonly [s: number]: 42 | 233
}

class D extends B {
    static readonly [s: string]: number
}

class ED extends D {
    static readonly [s: string]: boolean
    static readonly [s: number]: 1 
}

class DD extends D {
    static readonly [s: string]: 421
}

const a = B["f"];
const b =  B[42];
const c = D["f"]
const d = D[42]
const e = ED["f"]
const f = ED[42]
const g = DD["f"]
const h = DD[42]`,
      [],
    );
  });
  test("staticIndexSignature4", async () => {
    await expectPass(
      `
class B {
    static readonly [s: string]: number;
    static readonly [s: number]: 42 | 233
}

class D {
    static [s: string]: number;
    static [s: number]: 42 | 233
}

interface IB {
    static [s: string]: number;
    static [s: number]: 42 | 233;
}

declare const v: number
declare const i: IB
if (v === 0) {
    B.a = D.a
    B[2] = D[2]
} else if (v === 1) {
    D.a = B.a
    D[2] = B[2]
} else if (v === 2) {
    B.a = i.a
    B[2] = i[2]
    D.a = i.a
    D[2] = i [2]
} else if (v === 3) {
    i.a = B.a
    i[2] = B[2]
} else if (v === 4) {
    i.a = D.a
    i[2] = B[2]
}`,
      [],
    );
  });
  test("staticIndexSignature5", async () => {
    await expectPass(
      `
class B {
    static readonly [s: string]: number;
    static readonly [s: number]: 42 | 233
}

interface I {
    static readonly [s: string]: number;
    static readonly [s: number]: 42 | 233
}

type TA = (typeof B)["foo"]
type TB = (typeof B)[42]

type TC = (typeof B)[string]
type TD = (typeof B)[number]

type TE = keyof typeof B;

type TF = Pick<typeof B, number>
type TFI = Pick<I, number>
type TG = Omit<typeof B, number>
type TGI = Omit<I, number>`,
      [],
    );
  });
  test("staticIndexSignature6", async () => {
    await expectPass(
      `
function foo () {
    return class<T> {
        static [s: string]: number
        static [s: number]: 42

        foo(v: T) { return v }
    }
}

const C = foo()
C.a;
C.a = 1;
C[2];
C[2] = 42;

const c = new C<number>();
c.foo(1);`,
      [],
    );
  });
  test("staticIndexSignature7", async () => {
    await expectPass(
      `class X {
    static [index: string]: string;
    static x = 12; // Should error, incompatible with index signature
}
class Y {
    static [index: string]: string;
    static foo() {} // should error, incompatible with index signature
}`,
      [],
    );
  });
});
