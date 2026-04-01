import { describe, test } from "bun:test";
import { expectPass } from "./helpers";

describe("TSC: es2021", () => {
  test("es2021LocalesObjectArgument", async () => {
    await expectPass(
      `
const enUS = new Intl.Locale("en-US");
const deDE = new Intl.Locale("de-DE");
const jaJP = new Intl.Locale("ja-JP");

new Intl.ListFormat(enUS);
new Intl.ListFormat([deDE, jaJP]);
Intl.ListFormat.supportedLocalesOf(enUS);
Intl.ListFormat.supportedLocalesOf([deDE, jaJP]);`,
      [],
    );
  });
  test("intlDateTimeFormatRangeES2021", async () => {
    await expectPass(
      `
new Intl.DateTimeFormat().formatRange(new Date(0), new Date());
const [ part ] = new Intl.DateTimeFormat().formatRangeToParts(1000, 1000000000);
`,
      [],
    );
  });
  test("logicalAssignment1", async () => {
    await expectPass(
      `declare let a: string | undefined
declare let b: string | undefined
declare let c: string | undefined

declare let d: number | undefined
declare let e: number | undefined
declare let f: number | undefined

declare let g: 0 | 1 | 42
declare let h: 0 | 1 | 42
declare let i: 0 | 1 | 42


a &&= "foo"
b ||= "foo"
c ??= "foo"


d &&= 42
e ||= 42
f ??= 42

g &&= 42
h ||= 42
i ??= 42`,
      [],
    );
  });
  test("logicalAssignment10", async () => {
    await expectPass(
      `
var count = 0;
var obj = {};
function incr() {
    return ++count;
}

const oobj = {
    obj
}

obj[incr()] ??= incr();
oobj["obj"][incr()] ??= incr();
`,
      [],
    );
  });
  test("logicalAssignment2", async () => {
    await expectPass(
      `interface A {
    foo: {
        bar(): {
            baz: 0 | 1 | 42 | undefined | ''
        }
        baz: 0 | 1 | 42 | undefined | ''
    }
    baz: 0 | 1 | 42 | undefined | ''
}

declare const result: A
declare const a: A
declare const b: A
declare const c: A

a.baz &&= result.baz
b.baz ||= result.baz
c.baz ??= result.baz

a.foo["baz"] &&= result.foo.baz
b.foo["baz"] ||= result.foo.baz
c.foo["baz"] ??= result.foo.baz

a.foo.bar().baz &&= result.foo.bar().baz
b.foo.bar().baz ||= result.foo.bar().baz
c.foo.bar().baz ??= result.foo.bar().baz`,
      [],
    );
  });
  test("logicalAssignment3", async () => {
    await expectPass(
      `interface A {
    baz: 0 | 1 | 42 | undefined | ''
}

declare const result: A;
declare const a: A;
declare const b: A;
declare const c: A;

(a.baz) &&= result.baz;
(b.baz) ||= result.baz;
(c.baz) ??= result.baz;`,
      [],
    );
  });
  test("logicalAssignment4", async () => {
    await expectPass(
      `
function foo1(results: number[] | undefined) {
    (results ||= []).push(100);
}

function foo2(results: number[] | undefined) {
    (results ??= []).push(100);
}

function foo3(results: number[] | undefined) {
    results ||= [];
    results.push(100);
}

function foo4(results: number[] | undefined) {
    results ??= [];
    results.push(100);
}

interface ThingWithOriginal {
    name: string;
    original?: ThingWithOriginal
}
declare const v: number
function doSomethingWithAlias(thing: ThingWithOriginal | undefined, defaultValue: ThingWithOriginal | undefined) {
    if (v === 1) {
        if (thing &&= thing.original) {
            thing.name;
        }
    }
    else if (v === 2) {
        if (thing &&= defaultValue) {
            thing.name;
            defaultValue.name
        }
    }
    else if (v === 3) {
        if (thing ||= defaultValue) {
            thing.name;
            defaultValue.name;
        }
    }
    else {
        if (thing ??= defaultValue) {
            thing.name;
            defaultValue.name;
        }
    }
}`,
      [],
    );
  });
  test("logicalAssignment5", async () => {
    await expectPass(
      `
function foo1 (f?: (a: number) => void) {
    f ??= (a => a)
    f(42)
}

function foo2 (f?: (a: number) => void) {
    f ||= (a => a)
    f(42)
}

function foo3 (f?: (a: number) => void) {
    f &&= (a => a)
    f(42)
}

function bar1 (f?: (a: number) => void) {
    f ??= (f.toString(), (a => a))
    f(42)
}

function bar2 (f?: (a: number) => void) {
    f ||= (f.toString(), (a => a))
    f(42)
}

function bar3 (f?: (a: number) => void) {
    f &&= (f.toString(), (a => a))
    f(42)
}`,
      [],
    );
  });
  test("logicalAssignment6", async () => {
    await expectPass(
      `
function foo1(results: number[] | undefined, results1: number[] | undefined) {
    (results ||= (results1 ||= [])).push(100);
}

function foo2(results: number[] | undefined, results1: number[] | undefined) {
    (results ??= (results1 ??= [])).push(100);
}

function foo3(results: number[] | undefined, results1: number[] | undefined) {
    (results &&= (results1 &&= [])).push(100);
}`,
      [],
    );
  });
  test("logicalAssignment7", async () => {
    await expectPass(
      `
function foo1(results: number[] | undefined, results1: number[] | undefined) {
    (results ||= results1 ||= []).push(100);
}

function foo2(results: number[] | undefined, results1: number[] | undefined) {
    (results ??= results1 ??= []).push(100);
}

function foo3(results: number[] | undefined, results1: number[] | undefined) {
    (results &&= results1 &&= []).push(100);
}`,
      [],
    );
  });
  test("logicalAssignment8", async () => {
    await expectPass(
      `
declare const bar: { value?: number[] } | undefined

function foo1(results: number[] | undefined) {
    (results ||= bar?.value ?? []).push(100);
}

function foo2(results: number[] | undefined) {
    (results ??= bar?.value ?? []).push(100);
}

function foo3(results: number[] | undefined) {
    (results &&= bar?.value ?? []).push(100);
}`,
      [],
    );
  });
  test("logicalAssignment9", async () => {
    await expectPass(
      `declare let x: { a?: boolean };

x.a ??= true;
x.a &&= false;
`,
      [],
    );
  });
});
