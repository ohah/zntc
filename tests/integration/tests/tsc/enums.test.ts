import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: enums", () => {
  test("awaitAndYield", async () => {
    await expectError(
      `async function* test(x: Promise<number>) {
    enum E {
        foo = await x,
        baz = yield 1,
    }
}`,
      [],
    );
  });
  test("enumBasics", async () => {
    await expectPass(
      `// Enum without initializers have first member = 0 and successive members = N + 1
enum E1 {
    A,
    B,
    C
}

// Enum type is a subtype of Number
var x: number = E1.A;

// Enum object type is anonymous with properties of the enum type and numeric indexer
var e = E1;
var e: {
    readonly A: E1.A;
    readonly B: E1.B;
    readonly C: E1.C;
    readonly [n: number]: string;
};
var e: typeof E1;

// Reverse mapping of enum returns string name of property 
var s = E1[e.A];
var s: string;


// Enum with only constant members
enum E2 {
    A = 1, B = 2, C = 3
}

// Enum with only computed members
enum E3 {
    X = 'foo'.length, Y = 4 + 3, Z = +'foo'
}

// Enum with constant members followed by computed members
enum E4 {
    X = 0, Y, Z = 'foo'.length
}

// Enum with > 2 constant members with no initializer for first member, non zero initializer for second element
enum E5 {
    A,
    B = 3,
    C // 4
}

enum E6 {
    A,
    B = 0,
    C // 1
}

// Enum with computed member initializer of type 'any'
enum E7 {
    A = 'foo'['foo']
}

// Enum with computed member initializer of type number
enum E8 {
    B = 'foo'['foo']
}

//Enum with computed member intializer of same enum type
enum E9 {
    A,
    B = A
}

// (refer to .js to validate)
// Enum constant members are propagated
var doNotPropagate = [
    E8.B, E7.A, E4.Z, E3.X, E3.Y, E3.Z
];
// Enum computed members are not propagated
var doPropagate = [
    E9.A, E9.B, E6.B, E6.C, E6.A, E5.A, E5.B, E5.C
];

`,
      [],
    );
  });
  test("enumClassification", async () => {
    await expectPass(
      `
// An enum type where each member has no initializer or an initializer that specififes
// a numeric literal, a string literal, or a single identifier naming another member in
// the enum type is classified as a literal enum type. An enum type that doesn't adhere
// to this pattern is classified as a numeric enum type.

// Examples of literal enum types

enum E01 {
    A
}

enum E02 {
    A = 123
}

enum E03 {
    A = "hello"
}

enum E04 {
    A,
    B,
    C
}

enum E05 {
    A,
    B = 10,
    C
}

enum E06 {
    A = "one",
    B = "two",
    C = "three"
}

enum E07 {
    A,
    B,
    C = "hi",
    D = 10,
    E,
    F = "bye"
}

enum E08 {
    A = 10,
    B = "hello",
    C = A,
    D = B,
    E = C,
}

// Examples of numeric enum types with only constant members

enum E10 {}

enum E11 {
    A = +0,
    B,
    C
}

enum E12 {
    A = 1 << 0,
    B = 1 << 1,
    C = 1 << 2
}

// Examples of numeric enum types with constant and computed members

enum E20 {
    A = "foo".length,
    B = A + 1,
    C = +"123",
    D = Math.sin(1)
}
`,
      [],
    );
  });
  test("enumConstantMembers", async () => {
    await expectPass(
      `// Constant members allow negatives, but not decimals. Also hex literals are allowed
enum E1 {
    a = 1,
    b
}
enum E2 {
    a = - 1,
    b
}
enum E3 {
    a = 0.1,
    b // Error because 0.1 is not a constant
}

declare enum E4 {
    a = 1,
    b = -1,
    c = 0.1 // Not a constant
}

enum E5 {
    a = 1 / 0,
    b = 2 / 0.0,
    c = 1.0 / 0.0,
    d = 0.0 / 0.0,
    e = NaN,
    f = Infinity,
    g = -Infinity
}

const enum E6 {
    a = 1 / 0,
    b = 2 / 0.0,
    c = 1.0 / 0.0,
    d = 0.0 / 0.0,
    e = NaN,
    f = Infinity,
    g = -Infinity
}
`,
      [],
    );
  });
  test("enumConstantMemberWithString", async () => {
    await expectPass(
      `enum T1 {
    a = "1",
    b = "1" + "2",
    c = "1" + "2" + "3",
    d = "a" - "a",
    e = "a" + 1
}

enum T2 {
    a = "1",
    b = "1" + "2"
}

enum T3 {
    a = "1",
    b = "1" + "2",
    c = 1,
    d = 1 + 2
}

enum T4 {
    a = "1"
}

enum T5 {
    a = "1" + "2"
}

declare enum T6 {
    a = "1",
    b = "1" + "2"
}`,
      [],
    );
  });
  test("enumConstantMemberWithStringEmitDeclaration", async () => {
    await expectPass(
      `enum T1 {
    a = "1",
    b = "1" + "2",
    c = "1" + "2" + "3"
}

enum T2 {
    a = "1",
    b = "1" + "2"
}

enum T3 {
    a = "1",
    b = "1" + "2"
}

enum T4 {
    a = "1"
}

enum T5 {
    a = "1" + "2"
}

declare enum T6 {
    a = "1",
    b = "1" + "2"
}
`,
      [],
    );
  });
  test("enumConstantMemberWithTemplateLiterals", async () => {
    await expectPass(
      `enum T1 {
    a = \`1\`
}

enum T2 {
    a = \`1\`,
    b = "2",
    c = 3
}

enum T3 {
    a = \`1\` + \`1\`
}

enum T4 {
    a = \`1\`,
    b = \`1\` + \`1\`,
    c = \`1\` + "2",
    d = "2" + \`1\`,
    e = "2" + \`1\` + \`1\`
}

enum T5 {
    a = \`1\`,
    b = \`1\` + \`2\`,
    c = \`1\` + \`2\` + \`3\`,
    d = 1,
    e = \`1\` - \`1\`,
    f = \`1\` + 1,
    g = \`1\${"2"}3\`,
    h = \`1\`.length
}

enum T6 {
    a = 1,
    b = \`12\`.length
}

declare enum T7 {
    a = \`1\`,
    b = \`1\` + \`1\`,
    c = "2" + \`1\`
}
`,
      [],
    );
  });
  test("enumConstantMemberWithTemplateLiteralsEmitDeclaration", async () => {
    await expectPass(
      `enum T1 {
    a = \`1\`
}

enum T2 {
    a = \`1\`,
    b = "2",
    c = 3
}

enum T3 {
    a = \`1\` + \`1\`
}

enum T4 {
    a = \`1\`,
    b = \`1\` + \`1\`,
    c = \`1\` + "2",
    d = "2" + \`1\`,
    e = "2" + \`1\` + \`1\`
}

enum T5 {
    a = \`1\`,
    b = \`1\` + \`2\`,
    c = \`1\` + \`2\` + \`3\`,
    d = 1
}

enum T6 {
    a = 1,
    b = \`12\`.length
}

declare enum T7 {
    a = \`1\`,
    b = \`1\` + \`1\`,
    c = "2" + \`1\`
}
`,
      [],
    );
  });
  test("enumErrorOnConstantBindingWithInitializer", async () => {
    await expectPass(
      `
type Thing = {
  value?: string | number;
};

declare const thing: Thing;
const { value = "123" } = thing;

enum E {
  test = value,
}`,
      [],
    );
  });
  test("enumErrors", async () => {
    await expectError(
      `// Enum named with PredefinedTypes
enum any { }
enum number { }
enum string { }
enum boolean { }

// Enum with computed member initializer of type Number
enum E5 {
    C = new Number(30)
}

enum E9 {
    A,
    B = A
}

//Enum with computed member intializer of different enum type
// Bug 707850: This should be allowed
enum E10 {
    A = E9.A,
    B = E9.B
}

// Enum with computed member intializer of other types
enum E11 {
    A = true,
    B = new Date(),
    C = window,
    D = {},
    E = (() => 'foo')(),
}

// Enum with string valued member and computed member initializers
enum E12 {
    A = '',
    B = new Date(),
    C = window,
    D = {},
    E = 1 + 1,
    F = (() => 'foo')(),
}

// Enum with incorrect syntax
enum E13 {
    postComma,
    postValueComma = 1,

    postSemicolon;
    postColonValueComma: 2,
    postColonValueSemicolon: 3;
};

enum E14 { a, b: any "hello" += 1, c, d}
`,
      [],
    );
  });
  test("enumExportMergingES6", async () => {
    await expectPass(
      `export enum Animals {
	Cat = 1
}
export enum Animals {
	Dog = 2
}
export enum Animals {
	CatDog = Cat | Dog
}
`,
      [],
    );
  });
  test("enumMerging", async () => {
    await expectPass(
      `// Enum with only constant members across 2 declarations with the same root module
// Enum with initializer in all declarations with constant members with the same root module
namespace M1 {
    enum EImpl1 {
        A, B, C
    }

    enum EImpl1 {
        D = 1, E, F
    }

    export enum EConst1 {
        A = 3, B = 2, C = 1
    }

    export enum EConst1 {
        D = 7, E = 9, F = 8
    }

    var x = [EConst1.A, EConst1.B, EConst1.C, EConst1.D, EConst1.E, EConst1.F];
}

// Enum with only computed members across 2 declarations with the same root module 
namespace M2 {
    export enum EComp2 {
        A = 'foo'.length, B = 'foo'.length, C = 'foo'.length
    }

    export enum EComp2 {
        D = 'foo'.length, E = 'foo'.length, F = 'foo'.length
    }

    var x = [EComp2.A, EComp2.B, EComp2.C, EComp2.D, EComp2.E, EComp2.F];
}

// Enum with initializer in only one of two declarations with constant members with the same root module
namespace M3 {
    enum EInit {
        A,
        B
    }

    enum EInit {
        C = 1, D, E
    }
}

// Enums with same name but different root module
namespace M4 {
    export enum Color { Red, Green, Blue }
}
namespace M5 {
    export enum Color { Red, Green, Blue }
}

namespace M6.A {
    export enum Color { Red, Green, Blue }
}
namespace M6 {
    export namespace A {
        export enum Color { Yellow = 1 }
    }
    var t = A.Color.Yellow;
    t = A.Color.Red;
}
`,
      [],
    );
  });
  test("enumMergingErrors", async () => {
    await expectPass(
      `// Enum with constant, computed, constant members split across 3 declarations with the same root module
namespace M {
    export enum E1 { A = 0 }
    export enum E2 { C }
    export enum E3 { A = 0 }
}
namespace M {
    export enum E1 { B = 'foo'.length }
    export enum E2 { B = 'foo'.length }
    export enum E3 { C }
}
namespace M {
    export enum E1 { C }
    export enum E2 { A = 0 }
    export enum E3 { B = 'foo'.length }
}

// Enum with no initializer in either declaration with constant members with the same root module
namespace M1 {
    export enum E1 { A = 0 }
}
namespace M1 {
    export enum E1 { B }
}
namespace M1 {
    export enum E1 { C }
}


// Enum with initializer in only one of three declarations with constant members with the same root module
namespace M2 {
    export enum E1 { A }
}
namespace M2 {
    export enum E1 { B = 0 }
}
namespace M2 {
    export enum E1 { C }
}


`,
      [],
    );
  });
  test("enumShadowedInfinityNaN", async () => {
    await expectPass(
      `// https://github.com/microsoft/TypeScript/issues/54981

{
  let Infinity = {};
  enum En {
    X = Infinity
  }
}

{
  let NaN = {};
  enum En {
    X = NaN
  }
}`,
      [],
    );
  });
});
