import { describe, test, expect, afterEach } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { bundleAndRun, createFixture, runZts } from "./helpers";

// 런타임 헬퍼는 번들러가 자동 주입 (emitter.zig의 appendRuntimeHelpers)

describe("ES 다운레벨링 런타임 테스트", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  // ===== ES2015 =====

  describe("ES2015", () => {
    test("template literal → string concat", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const name = 'world'; console.log(`hello ${name}`);" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("hello world");
    });

    test("arrow function", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const add = (a: number, b: number) => a + b; console.log(add(1, 2));" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3");
    });

    test("arrow this capture", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Obj { x = 10; getX() { const fn = () => this.x; return fn(); } }
            console.log(new Obj().getX());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10");
    });

    test("let/const → var", async () => {
      const result = await bundleAndRun(
        { "index.ts": "let x = 1; const y = 2; console.log(x + y);" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3");
    });

    test("default params", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "function greet(name = 'world') { return 'hello ' + name; } console.log(greet());",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("hello world");
    });

    test("rest params", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "function sum(...nums: number[]) { return nums.reduce((a, b) => a + b, 0); } console.log(sum(1, 2, 3));",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("6");
    });

    test("spread array", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const a = [1, 2]; const b = [0, ...a, 3]; console.log(JSON.stringify(b));" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("[0,1,2,3]");
    });

    test("shorthand property", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const a = 1, b = 2; console.log(JSON.stringify({a, b}));" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('{"a":1,"b":2}');
    });

    test("destructuring object", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const { a, b } = { a: 1, b: 2, c: 3 }; console.log(a + b);" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3");
    });

    test("destructuring array", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const [x, y] = [10, 20]; console.log(x + y);" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("30");
    });

    test("destructuring rest (object)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "const { a, ...rest } = { a: 1, b: 2, c: 3 }; console.log(a, JSON.stringify(rest));",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('1 {"b":2,"c":3}');
    });

    test("destructuring rest (array)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "const [first, ...rest] = [1, 2, 3, 4]; console.log(first, JSON.stringify(rest));",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 [2,3,4]");
    });

    test("class basic", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo { x: number; constructor(x: number) { this.x = x; } double() { return this.x * 2; } }
            console.log(new Foo(5).double());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10");
    });

    test("class extends/super", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Animal { name: string; constructor(name: string) { this.name = name; } speak() { return this.name; } }
            class Dog extends Animal { speak() { return super.speak() + " barks"; } }
            console.log(new Dog("Rex").speak());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("Rex barks");
    });

    test("class getter/setter", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Box { _v = 0; get value() { return this._v; } set value(v: number) { this._v = v; } }
            const b = new Box(); b.value = 42; console.log(b.value);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("class IIFE: SWC 호환 패턴 (IIFE 스코프 격리 + classCallCheck)", async () => {
      const { dir, cleanup: cl } = await createFixture({
        "index.ts": `
          class Foo { greet() { return "hello"; } }
          console.log(new Foo().greet());
        `,
      });
      cleanup = cl;
      const outFile = join(dir, "out.js");
      const bundle = await runZts([
        "--bundle",
        join(dir, "index.ts"),
        "-o",
        outFile,
        "--target=es5",
      ]);
      expect(bundle.exitCode).toBe(0);

      const code = readFileSync(outFile, "utf-8");
      expect(code).toContain("(function()");
      expect(code).toContain("return Foo");
      expect(code).toContain("__classCallCheck");
    });

    test("class IIFE: extends 시 parent를 IIFE 매개변수로 전달", async () => {
      const { dir, cleanup: cl } = await createFixture({
        "index.ts": `
          class Base { x = 1; }
          class Child extends Base { y = 2; }
          console.log(new Child().x, new Child().y);
        `,
      });
      cleanup = cl;
      const outFile = join(dir, "out.js");
      const bundle = await runZts([
        "--bundle",
        join(dir, "index.ts"),
        "-o",
        outFile,
        "--target=es5",
      ]);
      expect(bundle.exitCode).toBe(0);

      const code = readFileSync(outFile, "utf-8");
      expect(code).toContain("function(_super)");
      expect(code).toContain("__extends(Child, _super)");
    });

    test("class IIFE: --global-identifier 리네이밍 시 IIFE 내부는 원본 이름 유지", async () => {
      const { dir, cleanup: cl } = await createFixture({
        "index.ts": `
          class Performance { mark() { return "ok"; } }
          console.log(new Performance().mark());
        `,
      });
      cleanup = cl;
      const outFile = join(dir, "out.js");
      const bundle = await runZts([
        "--bundle",
        join(dir, "index.ts"),
        "-o",
        outFile,
        "--target=es5",
        "--global-identifier=Performance",
      ]);
      expect(bundle.exitCode).toBe(0);

      const code = readFileSync(outFile, "utf-8");
      expect(code).toContain("Performance$1");
      expect(code).toContain("function Performance()");
      expect(code).toContain("return Performance");
    });

    test("class expression", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const MyClass = class { x: number; constructor(x: number) { this.x = x; } get() { return this.x; } };
            console.log(new MyClass(7).get());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("7");
    });

    test("generator .next()", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function* gen() { yield 1; yield 2; yield 3; }
            const g = gen();
            const arr: number[] = [];
            let r = g.next(); while (!r.done) { arr.push(r.value); r = g.next(); }
            console.log(JSON.stringify(arr));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("[1,2,3]");
    });

    test("generator return", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function* gen() { yield 1; return 99; }
            const g = gen();
            console.log(JSON.stringify(g.next()), JSON.stringify(g.next()));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('{"value":1,"done":false} {"value":99,"done":true}');
    });

    test("private field (#field → WeakMap)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo { #x = 10; getX() { return this.#x; } setX(v: number) { this.#x = v; } }
            const f = new Foo(); f.setX(42); console.log(f.getX());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("spread in function call", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "function add(a: number, b: number, c: number) { return a + b + c; } const args: [number, number, number] = [1, 2, 3]; console.log(add(...args));",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("6");
    });

    test("computed property", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const k = 'x'; const o = {[k]: 42}; console.log(o.x);" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("for-of array", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "const arr = [10, 20, 30]; let sum = 0; for (const x of arr) { sum += x; } console.log(sum);",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("60");
    });

    test("arrow arguments capture", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function outer() { const fn = () => arguments[0]; return fn(); }
            console.log(outer(42));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("class static method", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class MathUtil { static add(a: number, b: number) { return a + b; } }
            console.log(MathUtil.add(3, 4));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("7");
    });

    test("class field + constructor coexist", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo { x = 10; y: number; constructor(y: number) { this.y = y; } sum() { return this.x + this.y; } }
            console.log(new Foo(20).sum());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("30");
    });

    test("generator yield value receive", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function* gen() { const x = yield 1; return x; }
            const g = gen(); g.next(); const r = g.next(42);
            console.log(JSON.stringify(r));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('{"value":42,"done":true}');
    });

    test("nested destructuring", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": "const { a, b: { c } } = { a: 1, b: { c: 2 } }; console.log(a, c);",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 2");
    });

    test("destructuring default value", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const { a = 10, b = 20 } = { a: 1 }; console.log(a, b);" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 20");
    });

    test("multiple class with private fields", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class A { #v = 1; get() { return this.#v; } }
            class B { #v = 2; get() { return this.#v; } }
            console.log(new A().get(), new B().get());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 2");
    });

    test("nested arrow this capture", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function Outer(this: any) {
              this.val = 10;
              var inner = () => {
                var deep = () => this.val;
                return deep();
              };
              console.log(inner());
            }
            new (Outer as any)();
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10");
    });

    test("arrow arguments capture", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function outer() {
              var f = () => Array.from(arguments).join(',');
              return f();
            }
            console.log(outer(1,2,3));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1,2,3");
    });

    test("destructuring function parameter", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function greet({name, age}: {name:string, age:number}) {
              return name + ':' + age;
            }
            console.log(greet({name:'Alice', age:30}));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("Alice:30");
    });

    test("nested destructuring", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const obj = { a: { b: { c: 42 } } };
            var { a: { b: { c } } } = obj;
            console.log(c);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("array destructuring with skip", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const arr = [1, 2, 3, 4];
            var [a, , b] = arr;
            console.log(a, b);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 3");
    });

    test("for-of with destructuring", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const pairs: [string,number][] = [['a',1],['b',2]];
            var out: string[] = [];
            for (const [k,v] of pairs) { out.push(k + v); }
            console.log(out.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("a1,b2");
    });

    test("class with toString override", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Point {
              x: number; y: number;
              constructor(x: number, y: number) { this.x = x; this.y = y; }
              toString() { return this.x + ',' + this.y; }
            }
            console.log('' + new Point(3, 4));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3,4");
    });

    test("class extends with method override", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Animal {
              speak() { return 'animal'; }
            }
            class Dog extends Animal {
              speak() { return 'woof'; }
            }
            class Cat extends Animal {}
            console.log(new Dog().speak(), new Cat().speak());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("woof animal");
    });

    test("generator with multiple yields", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function* multi() {
              yield 'a';
              yield 'b';
              yield 'c';
            }
            var out = [];
            var it = multi();
            var r = it.next();
            while (!r.done) { out.push(r.value); r = it.next(); }
            console.log(out.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("a,b,c");
    });

    test("generator yield delegation", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function* inner() { yield 1; yield 2; }
            function* outer() { yield 0; yield* inner(); yield 3; }
            var out = [];
            var it = outer();
            var r = it.next();
            while (!r.done) { out.push(r.value); r = it.next(); }
            console.log(out.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("0,1,2,3");
    });

    test("template literal with multiple substitutions", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": "const name = 'world'; const n = 42; console.log(`hello ${name}, num=${n}`);",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("hello world, num=42");
    });

    test("spread in object literal (es5)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const a = { x: 1 };
            const b = { ...a, y: 2, ...{ z: 3 } };
            console.log(JSON.stringify(b));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('{"x":1,"y":2,"z":3}');
    });

    test("default + rest params combined", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function f(sep: string = ',', ...nums: number[]) {
              return nums.join(sep);
            }
            console.log(f(undefined, 1, 2, 3));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1,2,3");
    });

    test("class static field expression", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class C { static a = 1; static b = C.a + 1; static c = C.b * 2; }
            console.log(C.a, C.b, C.c);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 2 4");
    });

    test("computed property name", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const key = 'hello';
            const obj = { [key]: 'world', [1+1]: 'two' };
            console.log(obj.hello, obj[2]);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("world two");
    });

    // --- SWC 대비 추가 테스트: new.target ---

    test("new.target in constructor function (called with new)", async () => {
      const result = await bundleAndRun(
        { "index.ts": `function Foo() { console.log((new.target as any) === Foo); } new Foo();` },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true");
    });

    test("new.target undefined when called normally", async () => {
      const result = await bundleAndRun(
        { "index.ts": `function Foo() { console.log(new.target); } Foo();` },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("undefined");
    });

    test("new.target in class constructor", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo { constructor() { console.log((new.target as any) === Foo); } }
            new Foo();
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true");
    });

    // --- SWC 대비 추가 테스트: Arrow Functions ---

    test("arrow with destructuring parameter", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `const fn = ({a, b}: {a:number, b:number}) => a + b; console.log(fn({a:1, b:2}));`,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3");
    });

    test("arrow returning object literal", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `const fn = (x: number) => ({value: x}); console.log(JSON.stringify(fn(42)));`,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('{"value":42}');
    });

    test("arrow in array.map", async () => {
      const result = await bundleAndRun(
        { "index.ts": `console.log([1,2,3].map(x => x * 2).join(","));` },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("2,4,6");
    });

    test("immediately invoked arrow", async () => {
      const result = await bundleAndRun(
        { "index.ts": `console.log(((x: number) => x + 1)(9));` },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10");
    });

    test("nested arrow with this and arguments", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function outer(this: any) {
              this.x = 10;
              const mid = () => {
                const inner = () => this.x + arguments.length;
                return inner();
              };
              return mid();
            }
            console.log(outer.call({x: 0}, 'a', 'b'));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("12");
    });

    // --- SWC 대비 추가 테스트: Block Scoping ---

    test("for-loop let closure capture (_loop extraction)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const fns: Function[] = [];
            for (let i = 0; i < 3; i++) { fns.push(() => i); }
            console.log(fns.map(f => f()).join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("0,1,2");
    });

    // #784: block scoping 블록 단위 스코프 격리
    test("let in if block scope isolation (#784)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            let x = 1;
            if (true) { let x = 2; }
            console.log(x);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1");
    });

    test("sibling blocks with same let name (#784)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            let result = '';
            { let x = 'a'; result += x; }
            { let x = 'b'; result += x; }
            console.log(result);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("ab");
    });

    test("destructuring let in block scope isolation (#800)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            let x = 1;
            if (true) { let { x } = { x: 2 }; }
            console.log(x);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1");
    });

    test("array destructuring let in block scope isolation (#800)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            let a = 10;
            if (true) { let [a, b] = [20, 30]; }
            console.log(a);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10");
    });

    test("const in for loop accumulation", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            var sum = 0;
            for (let i = 0; i < 5; i++) { const v = i * 2; sum += v; }
            console.log(sum);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("20");
    });

    // #790: for-loop 내 object_property가 block scoping 스캔에서 무한 루프를 유발하던 버그 수정
    test("block scoping: for-let with nested if + object property (#790)", async () => {
      const { dir, cleanup: cl } = await createFixture({
        "index.ts": `
          function test(arr: {a: any, b: number}[]) {
            const result: any[] = [];
            for (let i = 0; i < arr.length; i++) {
              if (arr[i].a == null) {
                const y = arr[i].b;
                if (typeof y === 'number') {
                  result.push({ b: y });
                } else {
                  return null;
                }
              }
            }
            return result;
          }
          const out = test([{a: null, b: 42}, {a: null, b: 7}]);
          console.log(JSON.stringify(out));
        `,
      });
      cleanup = cl;
      const outFile = join(dir, "out.js");
      const transpile = await runZts([join(dir, "index.ts"), "-o", outFile, "--target=es5"]);
      expect(transpile.exitCode).toBe(0);

      const code = readFileSync(outFile, "utf-8");
      // let/const가 var로 변환되었는지 확인
      expect(code).not.toContain("let ");
      expect(code).not.toContain("const ");
      expect(code).toContain("var ");
    });

    // AST layout 정합성: export_default_declaration (unary) + jsx_fragment (list)
    test("export default + es5 target: layout mismatch 수정 확인", async () => {
      const { dir, cleanup: cl } = await createFixture({
        "index.ts": `
          function greet() { return "hello"; }
          export default greet;
        `,
      });
      cleanup = cl;
      const outFile = join(dir, "out.js");
      const transpile = await runZts([join(dir, "index.ts"), "-o", outFile, "--target=es5"]);
      expect(transpile.exitCode).toBe(0);
      const code = readFileSync(outFile, "utf-8");
      expect(code).toContain("export default greet");
    });

    test("jsx fragment in for-let: layout mismatch 수정 확인", async () => {
      const { dir, cleanup: cl } = await createFixture({
        "index.tsx": `
          const items: any[] = [];
          for (let i = 0; i < 3; i++) {
            items.push(<><span>{i}</span></>);
          }
          console.log(items.length);
        `,
      });
      cleanup = cl;
      const outFile = join(dir, "out.js");
      const transpile = await runZts([join(dir, "index.tsx"), "-o", outFile, "--target=es5"]);
      expect(transpile.exitCode).toBe(0);
      const code = readFileSync(outFile, "utf-8");
      // let/const가 var로 변환되었는지 확인
      expect(code).not.toContain("let ");
      expect(code).toContain("var ");
    });

    // #784: 중첩 블록에서 let 쉐도잉 격리
    test("let shadow in nested block (#784)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            let x = 'outer';
            { let x = 'inner'; }
            console.log(x);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("outer");
    });

    // --- SWC 대비 추가 테스트: Classes ---

    test("class with computed method name", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const key = 'greet';
            class Foo { [key]() { return 'hi'; } }
            console.log(new Foo().greet());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("hi");
    });

    test("3-level inheritance chain", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class A { x() { return 'A'; } }
            class B extends A { y() { return 'B'; } }
            class C extends B { z() { return this.x() + this.y() + 'C'; } }
            console.log(new C().z());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("ABC");
    });

    test("class property initializer referencing constructor param", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo {
              doubled: number;
              constructor(x: number) { this.doubled = x * 2; }
            }
            console.log(new Foo(5).doubled);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10");
    });

    test("class with static and instance methods combined", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Counter {
              count = 0;
              inc() { this.count++; return this; }
              static create() { return new Counter(); }
            }
            console.log(Counter.create().inc().inc().count);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("2");
    });

    test("class extends with super in constructor and method", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Base {
              name: string;
              constructor(name: string) { this.name = name; }
              greet() { return 'Hello ' + this.name; }
            }
            class Child extends Base {
              constructor(name: string) { super(name.toUpperCase()); }
              greet() { return super.greet() + '!'; }
            }
            console.log(new Child('world').greet());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("Hello WORLD!");
    });

    // --- SWC 대비 추가 테스트: Destructuring ---

    test("sparse array destructuring", async () => {
      const result = await bundleAndRun(
        { "index.ts": `const [,,third] = [1,2,3]; console.log(third);` },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3");
    });

    test("deeply nested mixed destructuring", async () => {
      const result = await bundleAndRun(
        { "index.ts": `const {a: [, {b}]} = {a: [1, {b: 42}]}; console.log(b);` },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("destructuring with computed property key", async () => {
      const result = await bundleAndRun(
        { "index.ts": `const key = 'x'; const {[key]: val} = {x: 42}; console.log(val);` },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("destructuring assignment (not declaration)", async () => {
      const result = await bundleAndRun(
        { "index.ts": `let a: number, b: number; ({a, b} = {a: 10, b: 20}); console.log(a + b);` },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("30");
    });

    test("destructuring in for-of with default value", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const arr = [{x:1}, {x:undefined as any}];
            const out: number[] = [];
            for (const {x=99} of arr) out.push(x);
            console.log(out.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1,99");
    });

    // --- SWC 대비 추가 테스트: For-of ---

    test("for-of with array of objects", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const items = [{v:10},{v:20},{v:30}];
            let sum = 0;
            for (const item of items) sum += item.v;
            console.log(sum);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("60");
    });

    test("for-of with let mutable binding", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const arr = [1,2,3]; let sum = 0;
            for (let x of arr) { x = x * 2; sum += x; }
            console.log(sum);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("12");
    });

    test("nested for-of loops", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const matrix = [[1,2],[3,4]];
            let sum = 0;
            for (const row of matrix) for (const v of row) sum += v;
            console.log(sum);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10");
    });

    test("for-of without block body", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const arr = [10, 20, 30];
            let sum = 0;
            for (const x of arr) sum += x;
            console.log(sum);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("60");
    });

    // --- SWC 대비 추가 테스트: Spread ---

    // #783: spread in new에서 bind.apply()를 괄호로 감싸기
    test("spread in new expression (#783)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Pair {
              a: number; b: number;
              constructor(a: number, b: number) { this.a = a; this.b = b; }
              sum() { return this.a + this.b; }
            }
            const args: [number, number] = [3, 4];
            console.log(new Pair(...args).sum());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("7");
    });

    test("multiple spreads in array", async () => {
      const result = await bundleAndRun(
        { "index.ts": `const a=[1,2], b=[3,4]; console.log([...a,...b,5].join(','));` },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1,2,3,4,5");
    });

    test("spread with method call preserving this", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const obj = {
              x: 1,
              fn(...args: number[]) { return this.x + args.reduce((a: number, b: number) => a + b, 0); }
            };
            console.log(obj.fn(...[2, 3]));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("6");
    });

    test("spread in nested function call", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function sum(...args: number[]) { return args.reduce((a, b) => a + b, 0); }
            const inner = [1, 2];
            console.log(sum(0, ...inner, 3));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("6");
    });

    // --- SWC 대비 추가 테스트: Parameters ---

    test("default param depending on previous param", async () => {
      const result = await bundleAndRun(
        { "index.ts": `function f(a: number, b = a * 2) { return b; } console.log(f(5));` },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10");
    });

    test("rest param with preceding default", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function f(sep: string = '-', ...items: string[]) { return items.join(sep); }
            console.log(f(undefined as any, 'a', 'b', 'c'));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("a-b-c");
    });

    test("destructuring parameter with default in class method", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo {
              greet({name = 'world'}: {name?: string} = {}) { return 'hi ' + name; }
            }
            console.log(new Foo().greet());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("hi world");
    });

    // --- SWC 대비 추가 테스트: Generators ---

    test("generator consumed manually with .next()", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function* range(a: number, b: number) { for (let i = a; i <= b; i++) yield i; }
            const out: number[] = [];
            const g = range(1, 5);
            let r = g.next();
            while (!r.done) { out.push(r.value); r = g.next(); }
            console.log(out.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1,2,3,4,5");
    });

    test("generator as class method with .next()", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo {
              *items() { yield 'a'; yield 'b'; yield 'c'; }
            }
            const out: string[] = [];
            const g = new Foo().items();
            let r = g.next();
            while (!r.done) { out.push(r.value); r = g.next(); }
            console.log(out.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("a,b,c");
    });

    test("infinite generator with manual consumption", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function* naturals() { let i = 1; while (true) yield i++; }
            const out: number[] = [];
            const g = naturals();
            for (let i = 0; i < 3; i++) out.push(g.next().value);
            console.log(out.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1,2,3");
    });

    test("generator with try/finally", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const log: string[] = [];
            function* gen() {
              try { yield 1; yield 2; }
              finally { log.push('finally'); }
            }
            const g = gen();
            log.push(String(g.next().value));
            log.push(String(g.next().value));
            g.next();
            console.log(log.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1,2,finally");
    });

    // --- SWC 대비 추가 테스트: Template Literals ---

    // #782: template literal 변환에서 보간 표현식에 괄호 추가
    test("template literal with expression (#782)", async () => {
      const result = await bundleAndRun(
        { "index.ts": "console.log(`${1 + 2} is three`);" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3 is three");
    });

    test("nested template literals", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const x = `a${`b${1}c`}d`; console.log(x);" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("ab1cd");
    });

    // #782: template literal 변환에서 ternary 표현식에 괄호 추가
    test("template literal with ternary expression (#782)", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const x = true; console.log(`val=${x ? 'yes' : 'no'}`);" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("val=yes");
    });

    // --- SWC 대비 추가 테스트: Tagged Template Literals ---

    test("tagged template basic", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function tag(strings: TemplateStringsArray, ...vals: any[]) {
              return strings[0] + vals[0] + strings[1];
            }
            console.log(tag\`hello \${'world'}!\`);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("hello world!");
    });

    test("tagged template .raw property", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function tag(s: TemplateStringsArray) { return s.raw[0]; }
            console.log(tag\`hello\\nworld\`);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("hello\\nworld");
    });

    test("tagged template caching (same site identity)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function tag(s: TemplateStringsArray) { return s; }
            function test() { return tag\`test\`; }
            const a = test();
            const b = test();
            console.log(a === b);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true");
    });

    test("tagged template with multiple substitutions", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function join(s: TemplateStringsArray, ...v: any[]) {
              let r = '';
              s.forEach((str: string, i: number) => { r += str + (v[i] !== undefined ? v[i] : ''); });
              return r;
            }
            console.log(join\`a\${1}b\${2}c\`);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("a1b2c");
    });

    // --- SWC 대비 추가 테스트: Computed Properties ---

    test("computed property with getter and setter", async () => {
      // 회귀 가드(#1397): getter/setter가 drop되지 않고 실제 accessor로 호출되는지 검증.
      // 이전엔 get/set이 Phase 2에서 skip돼 obj.val=42가 data property로 새로 생성되어 통과했음.
      const result = await bundleAndRun(
        {
          "index.ts": `
            const k = 'val';
            let hits = 0;
            const obj: any = {
              _v: 0,
              get [k]() { hits++; return this._v; },
              set [k](v: number) { hits++; this._v = v; }
            };
            obj.val = 42;
            console.log(obj.val, hits);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42 2");
    });

    test("#1397: data-computed key + getter/setter after — accessors preserved", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const k = 'y';
            let hits = 0;
            const obj: any = { _v: 0, [k]: 1, get x() { hits++; return this._v; }, set x(v: number) { hits++; this._v = v; } };
            obj.x = 42;
            console.log(obj.x, hits, obj.y);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42 2 1");
    });

    test("#1397: computed-getter-only triggers lowering", async () => {
      // getter/setter만 있고 일반 method/data-computed가 없을 때도 computed accessor key 때문에 lowering 필요.
      const result = await bundleAndRun(
        {
          "index.ts": `
            const k = 'y';
            let hits = 0;
            const obj: any = { _v: 5, get [k]() { hits++; return this._v; } };
            console.log(obj.y, hits);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("5 1");
    });

    test("#1397: computed-method + non-computed getter (mixed)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const k = 'compMethod';
            let callOrder: string[] = [];
            const obj: any = {
              [k]() { callOrder.push('m'); return 10; },
              get p() { callOrder.push('g'); return 20; },
            };
            const a = obj.compMethod();
            const b = obj.p;
            console.log(a, b, callOrder.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10 20 m,g");
    });

    test("multiple computed properties in one object", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const a = 'x', b = 'y';
            const obj: any = {[a]: 1, [b]: 2, z: 3};
            console.log(obj.x, obj.y, obj.z);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 2 3");
    });

    test("computed property with Symbol key", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const s = Symbol('test');
            const obj: any = {[s]: 42};
            console.log(obj[s]);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });
  });

  // ===== ES2016 (target=es2015) =====

  describe("ES2016 → es2015", () => {
    test("exponentiation **", async () => {
      const result = await bundleAndRun({ "index.ts": "console.log(2 ** 10);" }, "index.ts", [
        "--target=es2015",
      ]);
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1024");
    });

    test("exponentiation assignment **=", async () => {
      const result = await bundleAndRun(
        { "index.ts": "let x = 3; x **= 2; console.log(x);" },
        "index.ts",
        ["--target=es2015"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("9");
    });
  });

  // ===== ES2017 (target=es2016) =====

  describe("ES2017 → es2016", () => {
    test("async function", async () => {
      const result = await bundleAndRun(
        { "index.ts": "async function foo() { return 42; } foo().then(v => console.log(v));" },
        "index.ts",
        ["--target=es2016"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("async with await", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            async function add(a: number, b: number) {
              const x = await Promise.resolve(a);
              const y = await Promise.resolve(b);
              return x + y;
            }
            add(10, 32).then(v => console.log(v));
          `,
        },
        "index.ts",
        ["--target=es2016"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("async arrow function", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "const double = async (x: number) => x * 2; double(21).then(v => console.log(v));",
        },
        "index.ts",
        ["--target=es2016"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("async error handling", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            async function safe() {
              try {
                throw new Error("oops");
              } catch (e: any) {
                return e.message;
              }
            }
            safe().then(v => console.log(v));
          `,
        },
        "index.ts",
        ["--target=es2016"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("oops");
    });
  });

  // ===== ES5: async + generator 결합 (state machine) =====

  describe("ES5: async → state machine", () => {
    test("async function with multiple awaits", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            async function add(a: number, b: number) {
              const x = await Promise.resolve(a);
              const y = await Promise.resolve(b);
              return x + y;
            }
            add(10, 32).then(v => console.log(v));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("async arrow function", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "const double = async (x: number) => x * 2; double(21).then(v => console.log(v));",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("async with await in condition", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            async function check(x: number) {
              if (x > 0 && (await Promise.resolve(true))) {
                return "yes";
              }
              return "no";
            }
            check(1).then(v => console.log(v));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("yes");
    });

    test("generator for-of with yield", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function* gen(arr: number[]) {
              for (const x of arr) { yield x * 2; }
            }
            var it = gen([1, 2, 3]);
            var r = it.next();
            var result: number[] = [];
            while (!r.done) { result.push(r.value); r = it.next(); }
            console.log(result.join(","));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("2,4,6");
    });

    test("generator for-of with empty array", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function* gen(arr: number[]) {
              for (const x of arr) { yield x; }
            }
            var it = gen([]);
            console.log(it.next().done ? "empty" : "not empty");
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("empty");
    });

    test("flow match expression", async () => {
      const result = await bundleAndRun(
        {
          "index.js": `// @flow
            function classify(x) {
              return match (x) {
                1 => "one",
                2 => "two",
                _ => "other",
              };
            }
            console.log([classify(1), classify(2), classify(3)].join(","));
          `,
        },
        "index.js",
        ["--flow"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("one,two,other");
    });

    test("async for-of with await", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            async function process(items: number[]) {
              var results: number[] = [];
              for (const item of items) {
                var val = await Promise.resolve(item * 10);
                results.push(val);
              }
              return results;
            }
            process([1, 2, 3]).then(r => console.log(r.join(",")));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10,20,30");
    });

    test("async with try/catch/finally", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            async function safe() {
              try {
                throw new Error("oops");
              } catch (e: any) {
                return await Promise.resolve(e.message);
              }
            }
            safe().then(v => console.log(v));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("oops");
    });

    test("class async method", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Calculator {
              async add(a: number, b: number) {
                const x = await Promise.resolve(a);
                return x + b;
              }
            }
            new Calculator().add(10, 32).then(v => console.log(v));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("multiple awaits in expression (temp vars)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            async function sum() {
              const result = (await Promise.resolve(10)) + (await Promise.resolve(32));
              return result;
            }
            sum().then(v => console.log(v));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("destructuring default parameter", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function greet({name = "world"} = {}) {
              return "hello " + name;
            }
            console.log(greet());
            console.log(greet({name: "zts"}));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toContain("hello world");
      expect(result.runOutput).toContain("hello zts");
    });
  });

  // ===== ES2018 (target=es2017) =====

  describe("ES2018 → es2017", () => {
    test("object spread", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "const a = { x: 1, y: 2 }; const b = { ...a, z: 3 }; console.log(JSON.stringify(b));",
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('{"x":1,"y":2,"z":3}');
    });

    test("object spread override", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": "const a = { x: 1 }; const b = { ...a, x: 2 }; console.log(b.x);",
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("2");
    });
  });

  // ===== ES2019 (target=es2018) =====

  describe("ES2019 → es2018", () => {
    test("optional catch binding", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "let caught = false; try { throw new Error(); } catch { caught = true; } console.log(caught);",
        },
        "index.ts",
        ["--target=es2018"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true");
    });
  });

  // ===== ES2020 (target=es2019) =====

  describe("ES2020 → es2019", () => {
    test("nullish coalescing ??", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const a = null ?? 'default'; const b = 0 ?? 'default'; console.log(a, b);" },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("default 0");
    });

    test("optional chaining ?.", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const obj: any = { a: { b: 42 } }; console.log(obj?.a?.b, obj?.x?.y);" },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42 undefined");
    });

    test("multiple ?? chaining", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "const a = null; const b = undefined; const c = 0; console.log(a ?? b ?? c ?? 99);",
        },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("0");
    });

    test("?? with false-y values preserved", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const a = 0 ?? 'fallback';
            const b = '' ?? 'fallback';
            const c = false ?? 'fallback';
            const d = null ?? 'fallback';
            const e = undefined ?? 'fallback';
            console.log(a, b, c, d, e);
          `,
        },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("0  false fallback fallback");
    });

    test("?. with nullish base", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const a: any = null;
            const b: any = undefined;
            const c: any = { x: { y: 42 } };
            console.log(a?.x?.y, b?.x?.y, c?.x?.y);
          `,
        },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("undefined undefined 42");
    });

    test("optional chaining call ?.()", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "const obj: any = { fn: () => 'ok' }; console.log(obj.fn?.(), obj.missing?.());",
        },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("ok undefined");
    });
  });

  // ===== ES2021 (target=es2020) =====

  describe("ES2021 → es2020", () => {
    test("logical assignment ??=", async () => {
      const result = await bundleAndRun(
        { "index.ts": "let a: number | null = null; a ??= 10; console.log(a);" },
        "index.ts",
        ["--target=es2020"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10");
    });

    test("logical assignment ||=", async () => {
      const result = await bundleAndRun(
        { "index.ts": "let a = 0; a ||= 5; console.log(a);" },
        "index.ts",
        ["--target=es2020"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("5");
    });

    test("logical assignment &&=", async () => {
      const result = await bundleAndRun(
        { "index.ts": "let a = 1; a &&= 10; let b = 0; b &&= 10; console.log(a, b);" },
        "index.ts",
        ["--target=es2020"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10 0");
    });
  });

  // ===== ES2022 (target=es2021) =====

  describe("ES2022 → es2021", () => {
    test("class static block", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo { static value: number; static { Foo.value = 42; } }
            console.log(Foo.value);
          `,
        },
        "index.ts",
        ["--target=es2021"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("class fields (target=es5)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo { x = 1; static y = 2; }
            const f = new Foo(); console.log(f.x, Foo.y);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 2");
    });

    test("class static block with computed value", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Registry {
              static entries: string[] = [];
              static { Registry.entries.push('a', 'b'); }
              static { Registry.entries.push('c'); }
            }
            console.log(Registry.entries.join(','));
          `,
        },
        "index.ts",
        ["--target=es2021"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("a,b,c");
    });

    test("class static block (target=es5)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo { static value: number; static { Foo.value = 42; } }
            console.log(Foo.value);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("private method (#method → WeakSet)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo {
              #double(x: number) { return x * 2; }
              run() { return this.#double(21); }
            }
            console.log(new Foo().run());
          `,
        },
        "index.ts",
        ["--target=es2021"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("private method (target=es5)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Calc {
              #add(a: number, b: number) { return a + b; }
              #mul(a: number, b: number) { return a * b; }
              compute() { return this.#add(this.#mul(3, 4), 5); }
            }
            console.log(new Calc().compute());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("17");
    });

    test("private method with extends", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Base {
              value = 10;
            }
            class Child extends Base {
              #helper() { return this.value + 5; }
              run() { return this.#helper(); }
            }
            console.log(new Child().run());
          `,
        },
        "index.ts",
        ["--target=es2021"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("15");
    });

    test("private method brand check throws on non-instance", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo {
              #secret() { return 42; }
              run() { return this.#secret(); }
            }
            const foo = new Foo();
            const stolen = foo.run;
            try { stolen.call({}); console.log("no error"); }
            catch(e) { console.log(e instanceof TypeError ? "TypeError" : "other"); }
          `,
        },
        "index.ts",
        ["--target=es2021"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("TypeError");
    });

    test("private method with constructor", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Greeter {
              name: string;
              constructor(name: string) { this.name = name; }
              #format() { return "Hello, " + this.name; }
              greet() { return this.#format(); }
            }
            console.log(new Greeter("world").greet());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("Hello, world");
    });

    test("private method with extends (target=es5)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Animal {
              name: string;
              constructor(name: string) { this.name = name; }
            }
            class Dog extends Animal {
              #bark() { return this.name + " says woof"; }
              speak() { return this.#bark(); }
            }
            console.log(new Dog("Rex").speak());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("Rex says woof");
    });

    test("private instance field (#f = init → WeakMap)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class X { #f = 1; get(){ return this.#f; } }
            console.log(new X().get());
          `,
        },
        "index.ts",
        ["--target=es2021"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1");
    });

    test("private field read/write/increment", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class A {
              #x = 10;
              #y: number | undefined;
              inc() { this.#x++; return this.#x; }
              sety(v: number) { this.#y = v; return this.#y; }
            }
            const a = new A();
            console.log(a.inc(), a.inc(), a.sety(42));
          `,
        },
        "index.ts",
        ["--target=es2021"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("11 12 42");
    });

    test("private field uninitialized (#f;)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class X { #f; get(){ return this.#f; } set(v: number){ this.#f = v; } }
            const x = new X();
            console.log(x.get());
            x.set(7);
            console.log(x.get());
          `,
        },
        "index.ts",
        ["--target=es2021"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("undefined\n7");
    });

    test("private field with existing constructor (no super)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Greeter {
              name: string;
              #suffix = "!";
              constructor(name: string) { this.name = name; }
              greet() { return "Hello " + this.name + this.#suffix; }
            }
            console.log(new Greeter("world").greet());
          `,
        },
        "index.ts",
        ["--target=es2021"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("Hello world!");
    });
  });

  // ===== useDefineForClassFields=false =====

  describe("useDefineForClassFields=false", () => {
    test("instance field to constructor", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo { x = 1; y = 'hello'; }
            const f = new Foo();
            console.log(f.x, f.y);
          `,
        },
        "index.ts",
        ["--use-define-for-class-fields=false"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 hello");
    });

    test("static field outside class", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo { static x = 42; static y = 'hi'; }
            console.log(Foo.x, Foo.y);
          `,
        },
        "index.ts",
        ["--use-define-for-class-fields=false"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42 hi");
    });

    test("mixed instance + static + method", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Counter {
              count = 0;
              static instances = 0;
              constructor() { Counter.instances++; }
              inc() { this.count++; }
            }
            const c = new Counter();
            c.inc(); c.inc();
            console.log(c.count, Counter.instances);
          `,
        },
        "index.ts",
        ["--use-define-for-class-fields=false"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("2 1");
    });

    test("extends with field", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Base { a = 1; }
            class Child extends Base { b = 2; }
            const c = new Child();
            console.log(c.a, c.b);
          `,
        },
        "index.ts",
        ["--use-define-for-class-fields=false"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 2");
    });
  });

  // ===== experimentalDecorators =====

  describe("experimentalDecorators", () => {
    test("class decorator", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function sealed(ctor: any) { Object.seal(ctor); return ctor; }
            @sealed class Foo { x = 1; }
            console.log(new Foo().x, Object.isSealed(Foo));
          `,
        },
        "index.ts",
        ["--experimental-decorators"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 true");
    });

    test("method decorator", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const calls: string[] = [];
            function log(target: any, key: string, desc: PropertyDescriptor) {
              const orig = desc.value;
              desc.value = function(this: any, ...args: any[]) {
                calls.push(key);
                return orig.apply(this, args);
              };
            }
            class Calc {
              @log add(a: number, b: number) { return a + b; }
              @log mul(a: number, b: number) { return a * b; }
            }
            const c = new Calc();
            console.log(c.add(1, 2), c.mul(3, 4), calls.join(','));
          `,
        },
        "index.ts",
        ["--experimental-decorators"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3 12 add,mul");
    });

    test("property decorator (metadata)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const meta: Record<string, string[]> = {};
            function Column(target: any, key: string) {
              const name = target.constructor.name;
              if (!meta[name]) meta[name] = [];
              meta[name].push(key);
            }
            class User {
              @Column id: number = 0;
              @Column name: string = "";
              @Column email: string = "";
            }
            console.log(meta["User"]?.sort().join(','));
          `,
        },
        "index.ts",
        ["--experimental-decorators"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("email,id,name");
    });

    test("property decorator with setter intercept", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const log: string[] = [];
            function observable(target: any, key: string) {
              let val = target[key];
              Object.defineProperty(target, key, {
                get() { return val; },
                set(v) { val = v; log.push(key + '=' + v); },
                enumerable: true, configurable: true,
              });
            }
            class Store {
              @observable count = 0;
            }
            const s = new Store();
            s.count = 42;
            console.log(s.count, log.join(','));
          `,
        },
        "index.ts",
        ["--experimental-decorators"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42 count=0,count=42");
    });

    test("decorator factory", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function tag(name: string) {
              return function(ctor: any) { ctor._tag = name; return ctor; };
            }
            @tag("users") class User {}
            @tag("posts") class Post {}
            console.log((User as any)._tag, (Post as any)._tag);
          `,
        },
        "index.ts",
        ["--experimental-decorators"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("users posts");
    });

    test("multiple decorators (reverse order)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const order: string[] = [];
            function a(ctor: any) { order.push('a'); return ctor; }
            function b(ctor: any) { order.push('b'); return ctor; }
            function c(ctor: any) { order.push('c'); return ctor; }
            @a @b @c class Foo {}
            console.log(order.join(','));
          `,
        },
        "index.ts",
        ["--experimental-decorators"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      // decorators applied inner-to-outer (c → b → a)
      expect(result.runOutput).toBe("c,b,a");
    });

    test("decorator on class with extends", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function wrap(ctor: any) { ctor._wrapped = true; return ctor; }
            class Base { x = 1; }
            @wrap class Child extends Base { y = 2; }
            const c = new Child();
            console.log(c.x, c.y, (Child as any)._wrapped);
          `,
        },
        "index.ts",
        ["--experimental-decorators"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 2 true");
    });

    test("class + method + property combined", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const log: string[] = [];
            function entity(ctor: any) { ctor._entity = true; return ctor; }
            function col(target: any, key: string) { log.push('col:' + key); }
            function meth(target: any, key: string, desc: PropertyDescriptor) { log.push('meth:' + key); }
            @entity class User {
              @col id: number = 0;
              @col name: string = "";
              @meth greet() { return this.name; }
            }
            const u = new User();
            u.name = "Alice";
            console.log(u.greet(), (User as any)._entity, log.sort().join(','));
          `,
        },
        "index.ts",
        ["--experimental-decorators"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("Alice true col:id,col:name,meth:greet");
    });
  });

  describe("ES5 this→_this 치환", () => {
    test("object shorthand method 안 arrow function의 this 캡처", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const obj = {
              items: [1, 2, 3],
              sum() {
                let total = 0;
                this.items.forEach((x) => { total += x; });
                return total;
              }
            };
            console.log(obj.sum());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("6");
    });

    test("class field initializer에서 this→_this (super class)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Base {
              value = 10;
              getVal() { return this.value; }
            }
            class Child extends Base {
              doubled = this.getVal() * 2;
            }
            console.log(new Child().doubled);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("20");
    });

    test("class field initializer에서 object literal + ternary + this", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Base {
              flag = true;
              getFlag() { return this.flag; }
            }
            class Child extends Base {
              config = { active: this.getFlag() ? "yes" : "no" };
            }
            console.log(new Child().config.active);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("yes");
    });

    test("prototype getter/setter에서 this는 _this로 치환하지 않는다", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Base { _val = 0; }
            class Child extends Base {
              _data = 42;
              get data() { return this._data; }
              set data(v) { this._data = v; }
            }
            const c = new Child();
            c.data = 99;
            console.log(c.data);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("99");
    });

    test("super 없는 class의 field에서 this는 _this로 치환하지 않는다", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo {
              x = 10;
              doubled = this.x * 2;
            }
            console.log(new Foo().doubled);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("20");
    });
  });

  describe("ES2020 optional chaining 괄호", () => {
    test("a?.b !== c?.d 연산자 우선순위", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const a = { b: 1 };
            const c = { d: 2 };
            console.log(a?.b !== c?.d);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true");
    });

    test("null?.prop이 포함된 비교", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const a: any = null;
            const b = { x: 1 };
            console.log(a?.x === b?.x);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("false");
    });
  });
});
