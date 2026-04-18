import { describe, test, expect } from "bun:test";
import { createFixture, runZts } from "./helpers";
import { spawnSync } from "node:child_process";

// Stage 3 decorator + --target=es5 다운레벨링 검증.
// - Stage 3 decorator pass가 `let C = (() => { ... })()` 형태 IIFE를 emit한다.
// - transformer.zig가 visitNode 재방문으로 arrow/let/class/accessor/static block을 ES5로 추가 lowering.
// - static block 안의 `this`는 class name identifier로 치환되어야 한다 (class scope 소실).
async function transpileES5(code: string): Promise<string> {
  const fixture = await createFixture({ "input.ts": code });
  try {
    const result = await runZts([`${fixture.dir}/input.ts`, "--target=es5"]);
    if (result.exitCode !== 0) throw new Error(`zts failed: ${result.stderr}`);
    return result.stdout;
  } finally {
    await fixture.cleanup();
  }
}

function runInNode(code: string): string {
  const proc = spawnSync("node", ["--input-type=module", "-e", code], { encoding: "utf8" });
  if (proc.status !== 0) throw new Error(proc.stderr || proc.stdout);
  return proc.stdout.trim();
}

// ES5 syntax 금지 패턴: ES5 런타임 파서가 실패하는 구문이 출력에 남으면 회귀.
function expectNoEs6Syntax(output: string) {
  // class keyword
  expect(output).not.toMatch(/\bclass\s+[A-Za-z_$][\w$]*\s*\{/);
  expect(output).not.toMatch(/\bclass\s*\{/);
  // static { ... } 블록
  expect(output).not.toMatch(/^\s*static\s*\{/m);
  // accessor 키워드
  expect(output).not.toMatch(/\baccessor\s+[A-Za-z_$]/);
  // arrow function (expression body/block body 모두)
  expect(output).not.toMatch(/=>/);
  // let/const (block_scoping 다운레벨링 완료)
  expect(output).not.toMatch(/^\s*let\s+[A-Za-z_$]/m);
}

describe("Stage 3 decorator + --target=es5 다운레벨링", () => {
  test("method decorator + accessor field (이슈 본문 케이스)", async () => {
    const out = await transpileES5(`
function logged(target: any, ctx: any) {
  return function (this: any, ...args: any[]) { return target.apply(this, args); };
}
class C {
  accessor counter = 0;
  @logged tick() { this.counter += 1; return this.counter; }
}
const c = new C();
console.log(c.tick(), c.tick());
`);
    expectNoEs6Syntax(out);
    expect(runInNode(out)).toBe("1 2");
  });

  test("class-level decorator (addInitializer)", async () => {
    const out = await transpileES5(`
function addStatic(target: any, ctx: any) {
  ctx.addInitializer(() => { (target as any).tag = "TAGGED"; });
}
@addStatic
class A { hello() { return "hi"; } }
console.log(new A().hello(), (A as any).tag);
`);
    expectNoEs6Syntax(out);
    expect(runInNode(out)).toBe("hi TAGGED");
  });

  test("field decorator (init 변환) — arrow_this_depth leak 회귀 방지", async () => {
    const out = await transpileES5(`
function double(_v: any, _ctx: any) { return function (initial: number) { return initial * 2; }; }
class F { @double value = 10; }
console.log(new F().value);
`);
    expectNoEs6Syntax(out);
    // field init 안의 this가 _this로 잘못 치환되면 ReferenceError 발생 (과거 회귀).
    expect(runInNode(out)).toBe("20");
  });

  test("static method decorator", async () => {
    const out = await transpileES5(`
function wrap(target: any, _ctx: any) {
  return function (this: any, ...args: any[]) { return "W:" + target.apply(this, args); };
}
class S { @wrap static greet(name: string) { return "Hi " + name; } }
console.log(S.greet("bob"));
`);
    expectNoEs6Syntax(out);
    expect(runInNode(out)).toBe("W:Hi bob");
  });

  test("getter decorator", async () => {
    const out = await transpileES5(`
function log(target: any, ctx: any) {
  if (ctx.kind === "getter") return function (this: any) { return target.call(this) + "!"; };
  return target;
}
class G { _v = 5; @log get v() { return this._v; } set v(n: number) { this._v = n; } }
const g = new G(); console.log(g.v); g.v = 7; console.log(g.v);
`);
    expectNoEs6Syntax(out);
    expect(runInNode(out)).toBe("5!\n7!");
  });

  test("extends + class decorator", async () => {
    const out = await transpileES5(`
function tag(target: any, ctx: any) { ctx.addInitializer(() => { (target as any).tag = "X"; }); }
class Base { base() { return "B"; } }
@tag
class Child extends Base { child() { return this.base() + "-C"; } }
console.log(new Child().child(), (Child as any).tag);
`);
    expectNoEs6Syntax(out);
    expect(runInNode(out)).toBe("B-C X");
  });

  test("chained decorators (적용 순서)", async () => {
    const out = await transpileES5(`
function a(t: any, _c: any) { return function (this: any) { return "a(" + t.apply(this, arguments) + ")"; }; }
function b(t: any, _c: any) { return function (this: any) { return "b(" + t.apply(this, arguments) + ")"; }; }
class Ch { @a @b go() { return "core"; } }
console.log(new Ch().go());
`);
    expectNoEs6Syntax(out);
    expect(runInNode(out)).toBe("a(b(core))");
  });

  test("동일 scope에 여러 decorated class", async () => {
    const out = await transpileES5(`
function id(t: any, _c: any) { return t; }
class P { @id p() { return 1; } }
class Q { @id q() { return 2; } }
console.log(new P().p(), new Q().q());
`);
    expectNoEs6Syntax(out);
    expect(runInNode(out)).toBe("1 2");
  });

  // #1537 — Stage 3가 accessor에 붙인 `#_{name}_accessor_storage` private backing이
  // ES5 lowering에서 WeakMap으로 풀리는지. 핵심 회귀 가드.
  test("accessor + decorator의 private backing → WeakMap lowering (#1537)", async () => {
    const out = await transpileES5(`
function defaultTo(def: any) {
  return function (_: any, _ctx: any) {
    return { init(v: any) { return v == null ? def : v; } };
  };
}
class AccDec { @defaultTo(99) accessor x: any = undefined; }
const ad = new AccDec();
console.log(ad.x);
ad.x = 5;
console.log(ad.x);
`);
    expectNoEs6Syntax(out);
    // private field syntax(#name)가 출력에 남지 않아야 한다 — ES5 parser 실패 방지.
    expect(out).not.toMatch(/#[A-Za-z_]/);
    // accessor backing은 WeakMap으로 변환되어야 한다.
    expect(out).toMatch(/new WeakMap\(\)/);
    expect(runInNode(out)).toBe("99\n5");
  });

  // static block 내 this → class name 치환 (Stage 3 decorator와 독립된 일반 버그 수정)
  test("일반 static block: this → class name 치환", async () => {
    const out = await transpileES5(`
class D {
  static counter = 0;
  static { (D as any).x = 42; this.counter = 1; }
}
console.log(D.counter, (D as any).x);
`);
    expectNoEs6Syntax(out);
    expect(runInNode(out)).toBe("1 42");
  });
});
