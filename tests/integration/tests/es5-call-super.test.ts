import { afterEach, describe, expect, test } from 'bun:test';
import { bundleAndRun } from './helpers';

describe('ES5 __callSuper', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('derived constructor arrow 안의 super()도 lexical NewTarget을 사용한다', async () => {
    const result = await bundleAndRun(
      {
        'index.ts': `class Base { x: string; constructor(arg: string) { this.x = arg; } }
class Child extends Base {
  constructor() {
    const callSuper = () => super("foo");
    callSuper();
  }
}
const c = new Child();
console.log(c.x + ":" + (c instanceof Child) + ":" + (c instanceof Base));`,
      },
      'index.ts',
      ['--target=es5'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('foo:true:true');
  });

  test('4-level 상속 체인에서도 NewTarget이 top-level로 propagate된다', async () => {
    // _newTarget 가 매 레벨에서 this.constructor 로 캡쳐되지만, 모든 레벨에서
    // 동일하게 top NewTarget(D)을 가리켜야 prototype chain이 D→C→B→A 로 유지된다.
    const result = await bundleAndRun(
      {
        'index.ts': `class A { name() { return "A"; } }
class B extends A { name() { return "B>" + super.name(); } }
class C extends B { name() { return "C>" + super.name(); } }
class D extends C { name() { return "D>" + super.name(); } }
const d = new D();
console.log(d.name() + ":" + (d instanceof D) + ":" + (d instanceof A));`,
      },
      'index.ts',
      ['--target=es5'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('D>C>B>A:true:true');
  });

  test('multi-level chain의 default constructor 도 NewTarget propagate', async () => {
    // 중간 클래스에 constructor가 없으면 default constructor 가 생성됨.
    // default constructor 도 var _newTarget=this.constructor 캡쳐를 통해 동일한 NewTarget 사용.
    const result = await bundleAndRun(
      {
        'index.ts': `class A { constructor(public tag: string) {} }
class B extends A {} // default ctor
class C extends B {} // default ctor
class D extends C { constructor() { super("D-tag"); } }
const d = new D();
console.log(d.tag + ":" + (d instanceof D) + ":" + (d instanceof A));`,
      },
      'index.ts',
      ['--target=es5'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('D-tag:true:true');
  });

  test('extends Error 의 multi-level 에서도 native Error instance 보존', async () => {
    // Reflect.construct 는 NewTarget.prototype 을 [[Prototype]] 으로 갖는 native Error 생성.
    // 중간 클래스가 끼어있어도 NewTarget 이 top 으로 유지돼야 e instanceof AppError === true.
    const result = await bundleAndRun(
      {
        'index.ts': `class BaseErr extends Error {
  kind = "base";
}
class AppError extends BaseErr {
  constructor(msg: string) {
    super(msg);
    this.name = "AppError";
  }
}
const e = new AppError("boom");
console.log([
  e instanceof Error,
  e instanceof BaseErr,
  e instanceof AppError,
  e.message === "boom",
  e.name === "AppError",
].join(","));`,
      },
      'index.ts',
      ['--target=es5'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('true,true,true,true,true');
  });

  test('if/else 분기 양쪽 super() 도 동일 NewTarget 사용', async () => {
    // 한 derived constructor 에서 super()가 분기마다 호출되더라도 _newTarget 은
    // ctor 시작 1회 캡쳐로 공유 — 어느 분기든 prototype chain 동일.
    const result = await bundleAndRun(
      {
        'index.ts': `class Base { v: number; constructor(v: number) { this.v = v; } }
class Child extends Base {
  constructor(flag: boolean) {
    if (flag) super(1);
    else super(2);
  }
}
const a = new Child(true), b = new Child(false);
console.log(a.v + "/" + (a instanceof Child) + "," + b.v + "/" + (b instanceof Child));`,
      },
      'index.ts',
      ['--target=es5'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('1/true,2/true');
  });

  test('instance fields + arrow super 가 동시에 있어도 NewTarget 보존', async () => {
    // instance field 가 있으면 _this 별도 처리 + arrow 안 super() 도 closure 로
    // _newTarget 캡쳐 — 두 메커니즘이 같이 동작해야 함.
    const result = await bundleAndRun(
      {
        'index.ts': `class Base { tag: string; constructor(t: string) { this.tag = t; } }
class Child extends Base {
  count = 0;
  constructor() {
    const go = () => super("kid");
    go();
    this.count = 7;
  }
}
const c = new Child();
console.log(c.tag + "/" + c.count + "/" + (c instanceof Child) + "/" + (c instanceof Base));`,
      },
      'index.ts',
      ['--target=es5'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('kid/7/true/true');
  });

  test('super 인자에 constructor param + spread 혼합', async () => {
    // super(first, ...rest) — spread 가 array literal 로 들어가고 NewTarget 은 _newTarget.
    const result = await bundleAndRun(
      {
        'index.ts': `class Base {
  values: number[];
  constructor(label: string, ...nums: number[]) { this.values = [label.length, ...nums]; }
}
class Child extends Base {
  constructor(label: string, ...nums: number[]) { super(label, ...nums); }
}
const c = new Child("hi", 1, 2, 3);
console.log(c.values.join(",") + ":" + (c instanceof Child));`,
      },
      'index.ts',
      ['--target=es5'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('2,1,2,3:true');
  });

  test('TS parameter property 가 multi-level super 체인에서도 정확히 할당', async () => {
    // constructor(public x) 의 this.x=x 삽입 경로(#1471)와 _newTarget 캡쳐 경로가
    // 같은 derived constructor 안에서 충돌 없이 동작해야 한다.
    const result = await bundleAndRun(
      {
        'index.ts': `class A { constructor(public x: number) {} }
class B extends A { constructor(public y: number) { super(1); } }
class C extends B { constructor(public z: number) { super(2); } }
const c = new C(3);
console.log([c.x, c.y, c.z, c instanceof C, c instanceof A].join(","));`,
      },
      'index.ts',
      ['--target=es5'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('1,2,3,true,true');
  });

  test('derived constructor 가 super() 결과를 명시적으로 return', async () => {
    // ES2015 spec: derived constructor 에서 `return super(...)` 는 super() 의
    // 반환 객체를 derived 인스턴스로 사용. transformDerivedConstructorReturns 가
    // _this 별칭으로 변환하므로 instance 유지되어야 함.
    const result = await bundleAndRun(
      {
        'index.ts': `class Base { constructor(public tag: string) {} }
class Child extends Base {
  constructor() {
    return super("from-super");
  }
}
const c = new Child();
console.log(c.tag + ":" + (c instanceof Child) + ":" + (c instanceof Base));`,
      },
      'index.ts',
      ['--target=es5'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('from-super:true:true');
  });

  test('extends class expression 의 multi-level super', async () => {
    // 익명 중간 클래스를 extends — class C extends (class extends Base { ... }) { ... }
    // _Class 같은 internal 이름으로 lower 되어도 _newTarget 캡쳐는 동일.
    const result = await bundleAndRun(
      {
        'index.ts': `class Base { name() { return "Base"; } }
const Mid = class extends Base { name() { return "Mid>" + super.name(); } };
class C extends Mid { name() { return "C>" + super.name(); } }
const c = new C();
console.log(c.name() + ":" + (c instanceof C) + ":" + (c instanceof Base));`,
      },
      'index.ts',
      ['--target=es5'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('C>Mid>Base:true:true');
  });

  test('try/catch 안의 super() 도 동일 _newTarget 사용', async () => {
    // try 의 super() 가 throw 할 때 catch 의 super(fallback) 으로 복구.
    // _newTarget 은 ctor body 시작에 1번 캡쳐되어 try/catch 양쪽이 공유.
    const result = await bundleAndRun(
      {
        'index.ts': `class Base { constructor(public msg: string) { if (msg === "fail") throw new Error("nope"); } }
class Child extends Base {
  constructor(arg: string) {
    try { super(arg); }
    catch (e) { super("fallback"); }
  }
}
const a = new Child("ok"), b = new Child("fail");
console.log(a.msg + "/" + b.msg + ":" + (a instanceof Child) + ":" + (b instanceof Child));`,
      },
      'index.ts',
      ['--target=es5'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('ok/fallback:true:true');
  });

  test('super.x getter 도 multi-level chain 에서 정확히 동작', async () => {
    // __superGet helper 가 prototype chain 을 따라가는 native 동작 — _newTarget 변경의
    // 부수 효과로 super property 접근까지 깨지지 않는지 회귀 가드.
    const result = await bundleAndRun(
      {
        'index.ts': `class A { get value() { return "A"; } }
class B extends A { get value() { return "B>" + super.value; } }
class C extends B { get value() { return "C>" + super.value; } }
const c = new C();
console.log(c.value + ":" + (c instanceof C) + ":" + (c instanceof A));`,
      },
      'index.ts',
      ['--target=es5'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('C>B>A:true:true');
  });
});
