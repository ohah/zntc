import { describe, it, expect, afterEach } from "bun:test";
import { bundleAndRun, createFixture, runZts } from "./helpers";
import { join } from "node:path";

// TC39 Stage 3 Decorator E2E 테스트
// ZTS로 번들링 후 Bun으로 실행하여 런타임 동작 검증

describe("Stage 3 Decorators", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  // --- Class decorator ---

  it("class decorator receives class and context", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function log(cls: any, ctx: any) {
          console.log(ctx.kind + ":" + ctx.name);
          return cls;
        }
        @log class Foo {}
        new Foo();
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("class:Foo");
  });

  it("class decorator can replace class", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function wrap(cls: any, ctx: any) {
          return class extends cls {
            extra = true;
          };
        }
        @wrap class Foo {
          value = 42;
        }
        const f = new Foo() as any;
        console.log(f.value + "," + f.extra);
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("42,true");
  });

  it("multiple class decorators apply right to left", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        const order: string[] = [];
        function d1(cls: any, ctx: any) { order.push("d1"); return cls; }
        function d2(cls: any, ctx: any) { order.push("d2"); return cls; }
        @d1 @d2 class Foo {}
        console.log(order.join(","));
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    // decorator는 아래부터 위로 (오른쪽부터 왼쪽으로) 적용
    expect(result.runOutput).toContain("d2,d1");
  });

  // --- Method decorator ---

  it("method decorator receives function and context", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function log(fn: any, ctx: any) {
          console.log(ctx.kind + ":" + ctx.name);
          return fn;
        }
        class Foo {
          @log greet() { return "hello"; }
        }
        console.log(new Foo().greet());
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("method:greet");
    expect(result.runOutput).toContain("hello");
  });

  it("method decorator can wrap function", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function double(fn: any, ctx: any) {
          return function(this: any, ...args: any[]) {
            return fn.call(this, ...args) * 2;
          };
        }
        class Calc {
          @double compute() { return 21; }
        }
        console.log(new Calc().compute());
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("42");
  });

  // --- Getter/Setter decorator ---

  it("getter decorator works", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function log(fn: any, ctx: any) {
          console.log(ctx.kind + ":" + ctx.name);
          return fn;
        }
        class Foo {
          @log get x() { return 42; }
        }
        console.log(new Foo().x);
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("getter:x");
    expect(result.runOutput).toContain("42");
  });

  // --- Field decorator ---

  it("field decorator receives undefined and context", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function log(value: any, ctx: any) {
          console.log(ctx.kind + ":" + ctx.name + ":" + (value === undefined));
        }
        class Foo {
          @log x = 123;
        }
        new Foo();
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("field:x:true");
  });

  it("field decorator can transform initial value", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function multiply(factor: number) {
          return function(value: any, ctx: any) {
            return function(initialValue: number) {
              return initialValue * factor;
            };
          };
        }
        class Foo {
          @multiply(10) x = 5;
        }
        console.log(new Foo().x);
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("50");
  });

  // --- addInitializer ---

  it("addInitializer runs during construction", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function track(fn: any, ctx: any) {
          ctx.addInitializer(function(this: any) {
            console.log("init:" + this.constructor.name);
          });
          return fn;
        }
        class Foo {
          @track greet() { return "hi"; }
        }
        new Foo();
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("init:Foo");
  });

  // --- Class expression ---

  it("class expression with decorator", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function log(cls: any, ctx: any) {
          console.log(ctx.kind);
          return cls;
        }
        const Foo = @log class {};
        console.log(typeof Foo);
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("class");
    expect(result.runOutput).toContain("function");
  });

  // --- Static member decorator ---

  it("static method decorator", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function log(fn: any, ctx: any) {
          console.log(ctx.kind + ":" + ctx.name + ":static=" + ctx.static);
          return fn;
        }
        class Foo {
          @log static create() { return new Foo(); }
        }
        Foo.create();
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("method:create:static=true");
  });

  // --- Mixed decorators ---

  it("class + method + field mixed", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        const kinds: string[] = [];
        function track(target: any, ctx: any) {
          kinds.push(ctx.kind + ":" + ctx.name);
          return target;
        }
        @track class Foo {
          @track greet() {}
          @track x = 1;
        }
        new Foo();
        console.log(kinds.sort().join("|"));
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    // 3개 decorator 모두 실행
    expect(result.runOutput).toContain("class:Foo");
    expect(result.runOutput).toContain("field:x");
    expect(result.runOutput).toContain("method:greet");
  });

  // --- Decorator metadata (Symbol.metadata) ---

  it("metadata is set on class", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        // Symbol.metadata polyfill (Bun 1.x에서 아직 미지원)
        if (!("metadata" in Symbol)) {
          (Symbol as any).metadata = Symbol("Symbol.metadata");
        }
        function meta(value: any, ctx: any) {
          if (ctx.metadata) {
            ctx.metadata.decorated = true;
          }
          return value;
        }
        @meta class Foo {}
        const m = (Foo as any)[Symbol.metadata];
        console.log(m ? m.decorated : "no-metadata");
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("true");
  });

  // --- Private member decorator ---

  it("private method decorator context", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function log(fn: any, ctx: any) {
          console.log(ctx.kind + ":" + ctx.name + ":private=" + ctx.private);
          return fn;
        }
        class Foo {
          @log #secret() { return 42; }
        }
        new Foo();
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("method:#secret:private=true");
  });

  it("private field decorator context", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function log(value: any, ctx: any) {
          console.log(ctx.kind + ":" + ctx.name + ":private=" + ctx.private);
        }
        class Foo {
          @log #value = 42;
        }
        new Foo();
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("field:#value:private=true");
  });

  // --- Transpile (non-bundle) mode ---

  it("transpile mode outputs __esDecorate", async () => {
    const { dir, cleanup: c } = await createFixture({
      "input.ts": `
        function dec(cls: any, ctx: any) { return cls; }
        @dec class Foo {}
      `,
    });
    cleanup = c;

    const result = await runZts([join(dir, "input.ts")]);
    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("__esDecorate");
    expect(result.stdout).toContain("__runInitializers");
    expect(result.stdout).toContain('"class"');
  });

  // --- Setter decorator E2E ---

  it("setter decorator works", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function validate(fn: any, ctx: any) {
          return function(this: any, value: any) {
            if (typeof value !== "number") throw new Error("not a number");
            fn.call(this, value);
          };
        }
        class Foo {
          _x = 0;
          @validate set x(v: number) { this._x = v; }
          get x() { return this._x; }
        }
        const f = new Foo();
        f.x = 42;
        console.log(f.x);
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("42");
  });

  // --- Static field decorator E2E ---

  it("static field decorator", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function log(value: any, ctx: any) {
          console.log(ctx.kind + ":" + ctx.name + ":static=" + ctx.static);
        }
        class Counter {
          @log static count = 0;
        }
        console.log(Counter.count);
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("field:count:static=true");
    expect(result.runOutput).toContain("0");
  });

  // --- Multiple decorated fields ordering ---

  it("multiple decorated fields order", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        const order: string[] = [];
        function track(value: any, ctx: any) {
          order.push(ctx.name);
        }
        class Foo {
          @track a = 1;
          @track b = 2;
          @track c = 3;
        }
        new Foo();
        console.log(order.join(","));
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("a,b,c");
  });

  // --- Decorator factory with chaining ---

  it("decorator factory with arguments", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function tag(name: string) {
          return function(cls: any, ctx: any) {
            cls.tag = name;
            return cls;
          };
        }
        @tag("myComponent")
        class Component {}
        console.log((Component as any).tag);
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("myComponent");
  });

  // --- Accessor decorator E2E ---

  it("accessor decorator basic", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function log(target: any, ctx: any) {
          console.log(ctx.kind + ":" + ctx.name);
          return target;
        }
        class Foo {
          @log accessor x = 10;
        }
        const f = new Foo();
        console.log(f.x);
        f.x = 20;
        console.log(f.x);
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("accessor:x");
    expect(result.runOutput).toContain("10");
    expect(result.runOutput).toContain("20");
  });

  // --- Extends chain ---

  it("decorator on derived class", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function log(cls: any, ctx: any) {
          console.log("decorated:" + ctx.name);
          return cls;
        }
        class Base {
          base = true;
        }
        @log class Child extends Base {
          child = true;
        }
        const c = new Child();
        console.log(c.base + "," + c.child);
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("decorated:Child");
    expect(result.runOutput).toContain("true,true");
  });

  // --- Multiple addInitializer ---

  it("multiple addInitializer calls", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        const log: string[] = [];
        function init1(fn: any, ctx: any) {
          ctx.addInitializer(function() { log.push("init1"); });
          return fn;
        }
        function init2(fn: any, ctx: any) {
          ctx.addInitializer(function() { log.push("init2"); });
          return fn;
        }
        class Foo {
          @init1 @init2 method() {}
        }
        new Foo();
        console.log(log.join(","));
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    // addInitializer는 decorator 적용 순서 (오른쪽→왼쪽)로 등록됨
    expect(result.runOutput).toContain("init2,init1");
  });

  // --- Context access.has/get ---

  it("access.has and access.get work correctly", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        let savedAccess: any;
        function capture(fn: any, ctx: any) {
          savedAccess = ctx.access;
          return fn;
        }
        class Foo {
          @capture greet() { return "hello"; }
        }
        const obj = new Foo();
        console.log(savedAccess.has(obj));
        console.log(savedAccess.get(obj)());
        console.log(savedAccess.has({}));
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("true");
    expect(result.runOutput).toContain("hello");
    expect(result.runOutput).toContain("false");
  });
});
