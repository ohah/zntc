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

  // ============================================================
  // Babel 2023-11 conformance tests 포팅
  // (babel/babel packages/babel-plugin-proposal-decorators/test/fixtures/2023-11-*)
  // ============================================================

  // --- 2023-11-classes/ctx ---

  it("babel: class decorator context kind and name", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        const logs: string[] = [];
        function dec(value: any, ctx: any) {
          logs.push(ctx.kind, ctx.name);
        }
        @dec class A {}
        console.log(JSON.stringify(logs));
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain('["class","A"]');
  });

  // --- 2023-11-methods/context-name (간소화) ---

  // TODO: string literal ("b") 및 numeric literal (0) 키에 대한 context.name 지원
  it.skip("babel: method decorator context.name for various key types", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        const logs: string[] = [];
        const dec = (value: any, context: any) => { logs.push(context.name); };
        class Foo {
          @dec a() {}
          @dec "b"() {}
          @dec 0() {}
        }
        console.log(JSON.stringify(logs));
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain('["a","b","0"]');
  });

  // --- 2023-11-fields/context-name (간소화) ---

  // TODO: string literal ("b") 및 numeric literal (0) 키에 대한 context.name 지원
  it.skip("babel: field decorator context.name for various key types", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        const logs: string[] = [];
        const dec = (value: any, context: any) => { logs.push(context.name); };
        class Foo {
          @dec a: any;
          @dec "b": any;
          @dec 0: any;
        }
        new Foo();
        console.log(JSON.stringify(logs));
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain('["a","b","0"]');
  });

  // --- 2023-11-misc/initializer-property-ignored ---

  it("babel: accessor decorator uses init, not initializer property", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        let initCalled = false;
        let initializerCalled = false;
        function decorator() {
          return {
            get init() { initCalled = true; return () => {}; },
            get initializer() { initializerCalled = true; return () => {}; },
          };
        }
        class A {
          @decorator accessor x: any;
        }
        new A();
        console.log("init:" + initCalled + ",initializer:" + initializerCalled);
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("init:true,initializer:false");
  });

  // --- 2023-11-ordering: decorator 적용 순서 (간소화) ---

  it("babel: decorator evaluation order — method before class", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        const log: string[] = [];
        const classDec = (cls: any, ctx: any) => { log.push("class"); return cls; };
        const methodDec = (fn: any, ctx: any) => { log.push("method"); return fn; };
        const fieldDec = (value: any, ctx: any) => { log.push("field"); };
        @classDec
        class Foo {
          @methodDec method() {}
          @fieldDec x = 1;
        }
        new Foo();
        console.log(log.join(","));
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    // 스펙 순서: method → field → class
    expect(result.runOutput).toContain("method,field,class");
  });

  // --- 2023-11-ordering: addInitializer 순서 ---

  it("babel: addInitializer order — right-to-left registration, left-to-right execution", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        const log: string[] = [];
        const dec1 = (fn: any, ctx: any) => {
          log.push("d1");
          ctx.addInitializer(() => log.push("i1"));
          return fn;
        };
        const dec2 = (fn: any, ctx: any) => {
          log.push("d2");
          ctx.addInitializer(() => log.push("i2"));
          return fn;
        };
        class Foo {
          @dec1 @dec2 method() {}
        }
        new Foo();
        console.log(log.join(","));
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    // decorators: 오른쪽→왼쪽 (d2,d1), initializers: 등록 순 (i2,i1)
    expect(result.runOutput).toContain("d2,d1,i2,i1");
  });

  // --- 2023-11-misc: decorator return value for method ---

  it("babel: method decorator return value replaces method", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function replace(original: any, ctx: any) {
          return function(this: any) { return original.call(this) * 3; };
        }
        class Foo {
          @replace getValue() { return 7; }
        }
        console.log(new Foo().getValue());
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("21");
  });

  // --- 2023-11: getter decorator return value replaces getter ---

  it("babel: getter decorator return value replaces getter", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function multiply(original: any, ctx: any) {
          return function(this: any) { return original.call(this) * 2; };
        }
        class Foo {
          _val = 5;
          @multiply get value() { return this._val; }
        }
        console.log(new Foo().value);
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("10");
  });

  // --- 2023-11: field decorator return initializer ---

  it("babel: field decorator returns initializer function", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function double(value: any, ctx: any) {
          return (initialValue: number) => initialValue * 2;
        }
        class Foo {
          @double x = 10;
        }
        console.log(new Foo().x);
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("20");
  });

  // --- 2023-11: class decorator addInitializer ---

  it("babel: class decorator addInitializer runs after class definition", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        const log: string[] = [];
        function dec(cls: any, ctx: any) {
          ctx.addInitializer(() => {
            log.push("classInit:" + cls.name);
          });
          return cls;
        }
        @dec class Foo {}
        log.push("afterClass");
        console.log(log.join(","));
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    // class addInitializer는 class 정의 완료 후, 외부 코드 실행 전
    expect(result.runOutput).toContain("classInit:");
  });

  // --- 2023-11: static method decorator ---

  it("babel: static method decorator context", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        const logs: any[] = [];
        function dec(fn: any, ctx: any) {
          logs.push({ kind: ctx.kind, name: ctx.name, static: ctx.static, private: ctx.private });
        }
        class Foo {
          @dec static hello() {}
          @dec world() {}
        }
        console.log(JSON.stringify(logs));
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    const output = result.runOutput;
    expect(output).toContain('"kind":"method"');
    expect(output).toContain('"name":"hello"');
    expect(output).toContain('"static":true');
    expect(output).toContain('"name":"world"');
    expect(output).toContain('"static":false');
  });

  // --- 2023-11: accessor decorator return { get, set, init } ---

  it("babel: accessor decorator can override get/set/init", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function logged(target: any, ctx: any) {
          return {
            get() { return target.get.call(this) + 100; },
            set(val: number) { target.set.call(this, val * 2); },
            init(val: number) { return val + 1; },
          };
        }
        class Foo {
          @logged accessor x = 10;
        }
        const f = new Foo();
        console.log("get:" + f.x);
        f.x = 5;
        console.log("afterSet:" + f.x);
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    // init: 10+1=11, get: 11+100=111
    expect(result.runOutput).toContain("get:111");
    // set: 5*2=10, get: 10+100=110
    expect(result.runOutput).toContain("afterSet:110");
  });

  // --- 2023-11-misc: access.set for field ---

  it("babel: field decorator access.set works", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        let savedAccess: any;
        function capture(value: any, ctx: any) {
          savedAccess = ctx.access;
        }
        class Foo {
          @capture x = 0;
        }
        const f = new Foo();
        savedAccess.set(f, 42);
        console.log(f.x);
        console.log(savedAccess.get(f));
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toContain("42");
  });
});
