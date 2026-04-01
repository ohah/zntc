import { describe, test, expect, afterEach } from "bun:test";
import { bundleAndRun } from "./helpers";

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
});
