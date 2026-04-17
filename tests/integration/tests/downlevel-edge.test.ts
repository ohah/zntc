import { describe, test, expect, afterEach } from "bun:test";
import { bundleAndRun } from "./helpers";

describe("ES 다운레벨링 엣지케이스 (복합 조합)", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  describe("복합 함수 시그니처", () => {
    test("async arrow + destructuring + default param", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const fn = async ({ a = 1, b = 2 }: { a?: number; b?: number } = {}) => a + b;
            fn({ a: 10 }).then((v) => console.log(v));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("12");
    });

    test("async arrow + array destructuring + rest + default", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const fn = async ([head = 0, ...tail]: number[] = []) => head + tail.length;
            fn([5, 1, 2, 3]).then((v) => console.log(v));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("8");
    });

    test("default param이 다른 param 참조", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function fn(a: number, b: number = a * 2, c: number = a + b) { return c; }
            console.log(fn(3));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("9");
    });

    test("nested destructuring + default in async arrow", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const fn = async ({ user: { name = 'anon', age = 0 } = {} }: any = {}) =>
              \`\${name}-\${age}\`;
            fn({ user: { name: 'jin' } }).then((v) => console.log(v));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("jin-0");
    });

    test("rest 안에 destructuring (ES2018 object rest)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function fn({ a, ...rest }: { a: number; b: number; c: number }) {
              return a + rest.b + rest.c;
            }
            console.log(fn({ a: 1, b: 2, c: 3 }));
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("6");
    });

    test("computed key + destructuring + default", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const k = 'x';
            const obj = { x: 5 };
            const { [k]: v = 10 } = obj as any;
            console.log(v);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("5");
    });
  });

  describe("class private + static + decorator 조합", () => {
    // skip: private static field compound assignment(`#x++`) helper 호출 누락 — #1468
    test.skip("private field + static + getter", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Counter {
              static #count = 0;
              static inc() { Counter.#count++; }
              static get value() { return Counter.#count; }
            }
            Counter.inc(); Counter.inc(); Counter.inc();
            console.log(Counter.value);
          `,
        },
        "index.ts",
        ["--target=es2020"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3");
    });

    test("private method + private field 상호 호출", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Box {
              #value = 1;
              #double() { return this.#value * 2; }
              expose() { return this.#double(); }
            }
            console.log(new Box().expose());
          `,
        },
        "index.ts",
        ["--target=es2020"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("2");
    });

    test("static block + private static field", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class C {
              static #value: number;
              static {
                C.#value = 42;
              }
              static get v() { return C.#value; }
            }
            console.log(C.v);
          `,
        },
        "index.ts",
        ["--target=es2020"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("class field initializer가 상위 field 참조", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class A {
              x = 10;
              y = this.x + 5;
              z = this.x + this.y;
            }
            console.log(new A().z);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("25");
    });

    test("subclass field가 super 메서드 호출", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Base { greet() { return 'base'; } }
            class Child extends Base {
              tag = this.greet() + '-child';
            }
            console.log(new Child().tag);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("base-child");
    });
  });

  describe("optional chaining + logical assignment 중첩", () => {
    test("nested optional chaining + ??=", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const obj: any = { a: { b: { c: null } } };
            obj.a.b.c ??= 'default';
            console.log(obj.a.b.c);
          `,
        },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("default");
    });

    test("optional chaining call + spread arg", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const arr = [1, 2, 3];
            const obj: any = { fn: (...nums: number[]) => nums.reduce((a, b) => a + b, 0) };
            console.log(obj.fn?.(...arr));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("6");
    });

    test("optional chaining null short-circuit", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const a: any = null;
            let calls = 0;
            const fn = () => { calls++; return 1; };
            const r = a?.b(fn());
            console.log(r === undefined && calls === 0);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true");
    });

    test("?? 좌변에 optional chaining 결과", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const obj: any = { a: { b: undefined } };
            const v = obj?.a?.b ?? obj?.missing?.x ?? 'fallback';
            console.log(v);
          `,
        },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("fallback");
    });

    test("logical assignment 체인 (||= && &&= 혼합)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const o: any = { a: 0, b: 'x', c: null };
            o.a ||= 5;
            o.b &&= o.b + '!';
            o.c ??= 'def';
            console.log(JSON.stringify(o));
          `,
        },
        "index.ts",
        ["--target=es2020"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('{"a":5,"b":"x!","c":"def"}');
    });

    test("optional chaining 위 delete (ES2020 spec)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const obj: any = { a: { b: 1 } };
            const ok = delete obj?.a?.b;
            console.log(ok && !('b' in obj.a));
          `,
        },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true");
    });
  });

  describe("generator / async-await 복합", () => {
    test("generator + destructuring in for-of", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function* gen(): IterableIterator<[string, number]> {
              yield ['a', 1]; yield ['b', 2]; yield ['c', 3];
            }
            let sum = 0;
            for (const [, v] of gen()) sum += v;
            console.log(sum);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("6");
    });

    test("async function inside try/catch with await", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            async function run(): Promise<string> {
              try {
                await Promise.reject(new Error('boom'));
                return 'ok';
              } catch (e: any) {
                return 'caught:' + e.message;
              } finally {
                // no-op
              }
            }
            run().then((v) => console.log(v));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("caught:boom");
    });

    test("for-await-of (ES2018) → ES2017", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            async function* gen() { yield 1; yield 2; yield 3; }
            async function run() {
              let sum = 0;
              for await (const v of gen()) sum += v;
              return sum;
            }
            run().then((v) => console.log(v));
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("6");
    });

    // skip: ES5 generator 의 `yield*` delegate op 미구현 (일반 yield 로 변환됨) — #1470
    test.skip("yield* delegate + return value", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function* inner() { yield 1; yield 2; return 10; }
            function* outer() {
              const r: any = yield* inner();
              yield r;
            }
            const arr: any[] = [];
            for (const v of outer()) arr.push(v);
            console.log(arr.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1,2,10");
    });

    test("async generator + try-finally (resource cleanup)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const log: string[] = [];
            async function* gen() {
              try { yield 1; yield 2; } finally { log.push('done'); }
            }
            async function run() {
              for await (const v of gen()) log.push('v:' + v);
              return log.join('|');
            }
            run().then((v) => console.log(v));
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("v:1|v:2|done");
    });
  });

  describe("spread / rest 경계", () => {
    test("spread를 new 표현식 인자로 (+ parameter property)", async () => {
      // 두 직교 기능 동시 검증: spread `...args` 와 TS parameter property `public x` 가
      // ES5 다운레벨링 시 함께 동작하는지. 이전엔 parameter property `this.x = x` 누락으로 실패 (#1471).
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Point { constructor(public x: number, public y: number) {} }
            const args: [number, number] = [3, 4];
            const p = new Point(...args);
            console.log(p.x + p.y);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("7");
    });

    test("multiple spread mixed with literal in array", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const a = [1, 2]; const b = [4, 5];
            const c = [0, ...a, 3, ...b, 6];
            console.log(c.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("0,1,2,3,4,5,6");
    });

    test("object spread + 동일 키 덮어쓰기 순서", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const a = { x: 1, y: 2 };
            const b = { y: 20, z: 3 };
            const c = { ...a, ...b, x: 100 };
            console.log(JSON.stringify(c));
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('{"x":100,"y":20,"z":3}');
    });

    test("Symbol.iterator로 spread", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const set = new Set([1, 2, 3]);
            const arr = [0, ...set, 4];
            console.log(arr.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("0,1,2,3,4");
    });
  });

  describe("template literal / tagged template", () => {
    test("tagged template with expressions", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function tag(strings: TemplateStringsArray, ...values: any[]) {
              return strings.raw.join('|') + '#' + values.join(',');
            }
            const name = 'world';
            console.log(tag\`hello \${name}!\`);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("hello |!#world");
    });

    test("nested template literal", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const a = 'inner';
            const s = \`outer-\${\`mid-\${a}\`}-end\`;
            console.log(s);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("outer-mid-inner-end");
    });

    test("template literal with escape sequences", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const s = \`line1\\nline2\\t\\u{1F600}\`;
            console.log(s.split('\\n').length);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("2");
    });
  });

  describe("regex 다운레벨링", () => {
    test("dotAll flag (/s) → ES2017", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const re = /a.b/s;
            console.log(re.test('a\\nb'));
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true");
    });

    test("named capture group → strip to positional", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const m = 'abc-123'.match(/(?<word>[a-z]+)-(?<num>\\d+)/);
            console.log(m && m[1] + ':' + m[2]);
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("abc:123");
    });

    test("named backreference \\k<name>", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const re = /(?<dup>a+)b\\k<dup>/;
            console.log(re.test('aabaa'));
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true");
    });

    test("unicode brace escape \\u{...}", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const re = /\\u{1F600}/u;
            console.log(re.test('😀'));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true");
    });

    test("sticky flag (/y)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const re = /foo/y;
            re.lastIndex = 4;
            console.log(re.test('xxxxfoo'));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true");
    });

    test("lookbehind (?<=)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const re = /(?<=\\$)\\d+/;
            const m = 'price $42 here'.match(re);
            console.log(m && m[0]);
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("flags 조합 (giu)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const re = /foo/giu;
            const m = 'FOO foo Foo'.match(re);
            console.log(m && m.length);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3");
    });
  });

  describe("for-of / iteration 경계", () => {
    test("for-of over string (코드포인트)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            let count = 0;
            for (const _ of 'abc') count++;
            console.log(count);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3");
    });

    test("for-of with destructuring + index via entries", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const arr = ['a', 'b', 'c'];
            const out: string[] = [];
            for (const [i, v] of arr.entries()) out.push(\`\${i}:\${v}\`);
            console.log(out.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("0:a,1:b,2:c");
    });

    test("break/continue 안의 for-of (ES5 폴리필 동작)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            let sum = 0;
            for (const v of [1, 2, 3, 4, 5]) {
              if (v === 2) continue;
              if (v === 4) break;
              sum += v;
            }
            console.log(sum);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("4");
    });
  });

  describe("신규 ES feature", () => {
    test("BigInt literal (ES2020) — es2019 target", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const big = 9007199254740993n;
            console.log(typeof big, big.toString());
          `,
        },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("bigint 9007199254740993");
    });

    test("numeric separator (ES2021)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const n = 1_000_000;
            const hex = 0xFF_FF;
            console.log(n, hex);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1000000 65535");
    });

    test("exponentiation assignment (**=, ES2016)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            let x = 3;
            x **= 4;
            console.log(x);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("81");
    });

    test("Object.hasOwn (ES2022) — runtime 제공", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const obj = { a: 1 };
            console.log(Object.hasOwn(obj, 'a'), Object.hasOwn(obj, 'b'));
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true false");
    });

    test("Array.prototype.at (ES2022)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const arr = [10, 20, 30];
            console.log(arr.at(-1), arr.at(0));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("30 10");
    });

    test("private brand check (#x in obj, ES2022)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Box {
              #v = 1;
              static is(o: any) { return #v in o; }
            }
            const b = new Box();
            console.log(Box.is(b), Box.is({}));
          `,
        },
        "index.ts",
        ["--target=es2020"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true false");
    });

    test("optional catch binding (ES2019)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            try { throw new Error('x'); } catch { console.log('caught'); }
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("caught");
    });

    test("globalThis (ES2020)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            console.log(typeof globalThis);
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("object");
    });

    test("String.prototype.replaceAll (ES2021)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const s = 'a-b-c'.replaceAll('-', '_');
            console.log(s);
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("a_b_c");
    });

    test("Promise.allSettled (ES2020)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            Promise.allSettled([Promise.resolve(1), Promise.reject('e')]).then((r) => {
              console.log(r.map((x) => x.status).join(','));
            });
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("fulfilled,rejected");
    });
  });

  describe("iterator / async cleanup", () => {
    test("for-of break 시 iterator.return() 호출", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const log: string[] = [];
            const it: any = {
              [Symbol.iterator]() { return it; },
              next() { return { value: 1, done: false }; },
              return(v: any) { log.push('return'); return { value: v, done: true }; },
            };
            for (const _ of it) { log.push('iter'); break; }
            console.log(log.join('|'));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("iter|return");
    });

    test("for-of throw 시 iterator.return() 호출", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const log: string[] = [];
            const it: any = {
              [Symbol.iterator]() { return it; },
              next() { return { value: 1, done: false }; },
              return() { log.push('return'); return { done: true }; },
            };
            try { for (const _ of it) { log.push('iter'); throw new Error('x'); } } catch {}
            console.log(log.join('|'));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("iter|return");
    });

    test("for-await-of break + async iterator return()", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const log: string[] = [];
            async function* gen() {
              try { yield 1; yield 2; } finally { log.push('done'); }
            }
            async function run() {
              for await (const _v of gen()) { log.push('iter'); break; }
              return log.join('|');
            }
            run().then((v) => console.log(v));
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("iter|done");
    });

    test("generator throw → catch in body", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function* gen() {
              try { yield 1; } catch (e: any) { yield 'caught:' + e.message; }
            }
            const g = gen();
            const a = g.next().value;
            const b = g.throw!(new Error('boom')).value;
            console.log(a, b);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 caught:boom");
    });

    test("generator return() 종료 시 finally 실행", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const log: string[] = [];
            function* gen() {
              try { yield 1; yield 2; } finally { log.push('done'); }
            }
            const g = gen();
            g.next();
            g.return!(undefined);
            console.log(log.join('|'));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("done");
    });
  });

  describe("destructuring 경계", () => {
    test("array hole (sparse) destructuring", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const [, , c] = [1, 2, 3, 4];
            console.log(c);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3");
    });

    test("object destructuring rename + default", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const { a: x = 10, b: y = 20 } = { a: 1 } as any;
            console.log(x, y);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 20");
    });

    test("destructuring in catch binding", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            try { throw { code: 42, msg: 'x' }; } catch ({ code, msg }: any) { console.log(code, msg); }
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42 x");
    });

    test("nested array+object destructuring + default", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const data = [{ name: 'A' }, { name: 'B', age: 30 }];
            const [{ name: n1 }, { name: n2, age: a2 = 0 }] = data;
            console.log(n1, n2, a2);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("A B 30");
    });

    test("for-of with object destructuring + rename", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const arr = [{ id: 1 }, { id: 2 }];
            const out: number[] = [];
            for (const { id: x } of arr) out.push(x);
            console.log(out.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1,2");
    });
  });

  describe("class 추가 케이스", () => {
    test("class expression (named) self-reference", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const C = class Self {
              static make() { return new Self(); }
            };
            console.log(C.make() instanceof C);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true");
    });

    test("computed method name in class", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const k = 'greet';
            class C { [k]() { return 'hi'; } }
            console.log((new C() as any).greet());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("hi");
    });

    test("class extends 표현식 (mixin)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const Base = class { greet() { return 'base'; } };
            class C extends Base { tag() { return this.greet() + '!'; } }
            console.log(new C().tag());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("base!");
    });

    test("super.method()를 arrow function 안에서", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Base { greet() { return 'base'; } }
            class C extends Base {
              wrap() { const fn = () => super.greet() + '!'; return fn(); }
            }
            console.log(new C().wrap());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("base!");
    });

    test("new.target in constructor", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class C { name: string; constructor() { this.name = new.target?.name ?? '?'; } }
            console.log(new C().name);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("C");
    });

    test("getter/setter 둘 다 있는 class", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class C {
              _v = 0;
              get v() { return this._v; }
              set v(x: number) { this._v = x * 2; }
            }
            const c = new C(); c.v = 5;
            console.log(c.v);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10");
    });

    test("static method가 다른 static method 호출", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class M {
              static a() { return 1; }
              static b() { return M.a() + 2; }
            }
            console.log(M.b());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3");
    });
  });

  describe("TS-specific", () => {
    test("enum reverse mapping", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            enum Color { Red = 1, Green = 2 }
            console.log(Color[1], Color.Green);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("Red 2");
    });

    test("const enum inline", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const enum E { A = 10, B = 20 }
            console.log(E.A + E.B);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("30");
    });

    test("string enum", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            enum S { A = 'a', B = 'b' }
            console.log(S.A + S.B);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("ab");
    });

    test("namespace + enum 조합", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            namespace NS {
              export enum E { X = 1, Y = 2 }
              export const sum = E.X + E.Y;
            }
            console.log(NS.sum);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3");
    });

    test("parameter property + readonly + 추가 본문", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class P {
              constructor(public readonly id: number, private name: string) {
                this.name = name.toUpperCase();
              }
              describe() { return this.id + ':' + this.name; }
            }
            console.log(new P(1, 'kim').describe());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1:KIM");
    });

    test("type assertion + non-null assertion 조합", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const x: any = '42';
            const n = (x as string)!.length;
            console.log(n);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("2");
    });
  });

  describe("regex 추가 엣지", () => {
    test("named group + lookbehind 조합", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const re = /(?<=\\$)(?<num>\\d+)/;
            const m = '$42'.match(re);
            console.log(m && m[0], m && m[1]);
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42 42");
    });

    test("non-capturing group + alternation", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const re = /(?:foo|bar)\\d+/g;
            const m = 'foo1 bar2 baz3'.match(re);
            console.log(m && m.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("foo1,bar2");
    });

    test("regex in dynamic RegExp() constructor", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const re = new RegExp('(?<n>\\\\d+)', 'g');
            const m = 'a1 b2'.match(re);
            console.log(m && m.join(','));
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1,2");
    });

    // skip: regex named group strip 시 `String.replace` replacement 의 `$<name>` 미변환 — #1473
    test.skip("multiple named groups + replace string $<name>", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const r = '2020-01-15'.replace(/(?<y>\\d{4})-(?<m>\\d{2})-(?<d>\\d{2})/, '$<d>/$<m>/$<y>');
            console.log(r);
          `,
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("15/01/2020");
    });

    test("regex literal escape in character class", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const re = /[\\u0041-\\u005A]/;
            console.log(re.test('A'), re.test('a'));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true false");
    });
  });

  describe("cross-target matrix (같은 코드, 여러 target)", () => {
    const code = `
      class Counter {
        count = 0;
        inc(n: number = 1) { this.count += n; return this; }
      }
      const c = new Counter();
      c.inc().inc(2).inc();
      const arr = [c.count, ...[c.count + 1]];
      console.log(arr.join(','));
    `;
    const targets = ["es5", "es2015", "es2017", "es2020"] as const;
    for (const t of targets) {
      test(`동일 코드 — target=${t}`, async () => {
        const result = await bundleAndRun({ "index.ts": code }, "index.ts", [`--target=${t}`]);
        cleanup = result.cleanup;
        expect(result.exitCode).toBe(0);
        expect(result.runOutput).toBe("4,5");
      });
    }
  });

  describe("미해결 (알려진 한계)", () => {
    test.todo("named capture group의 .groups 객체 접근 (Hermes regex 한계)", () => {
      // const m = 'abc'.match(/(?<x>a)/);
      // expect(m?.groups?.x).toBe('a');
      // 현재 named group을 strip만 하므로 groups 객체가 생성되지 않음
    });

    test.todo("regex /v flag (ES2024 unicodeSets) 다운레벨링");
  });
});
