import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: es6/shorthandPropertyAssignment", () => {
  test("objectLiteralShorthandProperties", async () => {
    await expectPass(
      `var a, b, c;

var x1 = {
    a
};

var x2 = {
    a,
}

var x3 = {
    a: 0,
    b,
    c,
    d() { },
    x3,
    parent: x3
};

`,
      [],
    );
  });
  test("objectLiteralShorthandPropertiesAssignment", async () => {
    await expectPass(
      `// @target: es2015
var id: number = 10000;
var name: string = "my name";

var person: { name: string; id: number } = { name, id };
function foo( obj:{ name: string }): void { };
function bar(name: string, id: number) { return { name, id }; }
function bar1(name: string, id: number) { return { name }; }
function baz(name: string, id: number): { name: string; id: number } { return { name, id }; }

foo(person);
var person1 = bar("Hello", 5);
var person2: { name: string } = bar("Hello", 5);
var person3: { name: string; id:number } = bar("Hello", 5);
`,
      [],
    );
  });
  test("objectLiteralShorthandPropertiesAssignmentError", async () => {
    await expectPass(
      `// @target: es2015
var id: number = 10000;
var name: string = "my name";

var person: { b: string; id: number } = { name, id };  // error
var person1: { name, id };  // ok
function foo(name: string, id: number): { id: string, name: number } { return { name, id }; }  // error
function bar(obj: { name: string; id: boolean }) { }
bar({ name, id });  // error

`,
      [],
    );
  });
  test("objectLiteralShorthandPropertiesAssignmentErrorFromMissingIdentifier", async () => {
    await expectPass(
      `// @target: es2015
var id: number = 10000;
var name: string = "my name";

var person: { b: string; id: number } = { name, id };  // error
function bar(name: string, id: number): { name: number, id: string } { return { name, id }; }  // error
function foo(name: string, id: number): { name: string, id: number } { return { name, id }; }  // error
var person1: { name, id }; // ok
var person2: { name: string, id: number } = bar("hello", 5);
`,
      [],
    );
  });
  test("objectLiteralShorthandPropertiesAssignmentES6", async () => {
    await expectPass(
      `// @lib: es5
var id: number = 10000;
var name: string = "my name";

var person: { name: string; id: number } = { name, id };
function foo(obj: { name: string }): void { };
function bar(name: string, id: number) { return { name, id }; }
function bar1(name: string, id: number) { return { name }; }
function baz(name: string, id: number): { name: string; id: number } { return { name, id }; }

foo(person);
var person1 = bar("Hello", 5);
var person2: { name: string } = bar("Hello", 5);
var person3: { name: string; id: number } = bar("Hello", 5);
`,
      [],
    );
  });
  test("objectLiteralShorthandPropertiesErrorFromNoneExistingIdentifier", async () => {
    await expectPass(
      `var x = {
    x, // OK
    undefinedVariable // Error
}
`,
      [],
    );
  });
  test("objectLiteralShorthandPropertiesErrorFromNotUsingIdentifier", async () => {
    await expectError(
      `// errors
var y = {
    "stringLiteral",
    42,
    get e,
    set f,
    this,
    super,
    var,
    class,
    typeof
};

var x = {
    a.b,
    a["ss"],
    a[1],
};

var v = { class };  // error`,
      [],
    );
  });
  test("objectLiteralShorthandPropertiesErrorWithModule", async () => {
    await expectError(
      `// module export
var x = "Foo";
namespace m {
    export var x;
}

namespace n {
    var z = 10000;
    export var y = {
        m.x  // error
    };
}

m.y.x;
`,
      [],
    );
  });
  test("objectLiteralShorthandPropertiesES6", async () => {
    await expectPass(
      `var a, b, c;

var x1 = {
    a
};

var x2 = {
    a,
}

var x3 = {
    a: 0,
    b,
    c,
    d() { },
    x3,
    parent: x3
};

`,
      [],
    );
  });
  test("objectLiteralShorthandPropertiesFunctionArgument", async () => {
    await expectPass(
      `// @target: es2015
var id: number = 10000;
var name: string = "my name";

var person = { name, id };

function foo(p: { name: string; id: number }) { }
foo(person);


var obj = { name: name, id: id };`,
      [],
    );
  });
  test("objectLiteralShorthandPropertiesFunctionArgument2", async () => {
    await expectPass(
      `// @target: es2015
var id: number = 10000;
var name: string = "my name";

var person = { name, id };

function foo(p: { a: string; id: number }) { }
foo(person);  // error
`,
      [],
    );
  });
  test("objectLiteralShorthandPropertiesWithModule", async () => {
    await expectPass(
      `// module export

namespace m {
    export var x;
}

namespace m {
    var z = x;
    var y = {
        a: x,
        x
    };
}
`,
      [],
    );
  });
  test("objectLiteralShorthandPropertiesWithModuleES6", async () => {
    await expectPass(
      `
namespace m {
    export var x;
}

namespace m {
    var z = x;
    var y = {
        a: x,
        x
    };
}
`,
      [],
    );
  });
});
