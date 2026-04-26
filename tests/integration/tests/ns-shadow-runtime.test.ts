import { describe, test, expect, afterEach } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { bundleAndRun, createFixture, runNode, runZts } from "./helpers";

/**
 * Runtime regression for `import * as M; const x = (i) => M.x(i)` self-shadow.
 *
 * `bundler_test/ns_member_shadow.zig` already has string-based assertions that lock
 * the emitted code shape, but a regression that produces semantically broken output
 * (e.g. `(i) => setSelectedLog(i)` calling itself instead of the namespace member)
 * can slip through if the substring patterns happen to match by accident. These
 * tests bundle each fixture, execute the result, and assert the program prints the
 * expected output without stack overflow or `ReferenceError`.
 */

describe("ns shadow runtime", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test.concurrent("LogBox pattern: nested const collides with namespace member, must not self-recurse", async () => {
    const r = await bundleAndRun(
      {
        "data.js": `export function setSelectedLog(idx) { return "real:" + idx; }`,
        "container.js": `import * as LogBoxData from './data.js';
export function Container(props) {
  const setSelectedLog = (i) => LogBoxData.setSelectedLog(i);
  return setSelectedLog(props.idx);
}`,
        "entry.js": `import { Container } from './container.js';
console.log(Container({ idx: 7 }));`,
      },
      "entry.js",
    );
    cleanup = r.cleanup;
    expect(r.runStderr).not.toContain("Maximum call stack");
    expect(r.runStderr).not.toContain("ReferenceError");
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("real:7");
  });

  test.concurrent("nested function inside Container: same shadowing rule applies", async () => {
    const r = await bundleAndRun(
      {
        "data.js": `export function helper(x) { return "data:" + x; }`,
        "deep.js": `import * as Mod from './data.js';
export function outer(z) {
  function inner() {
    const helper = (i) => Mod.helper(i);
    return helper(z);
  }
  return inner();
}`,
        "entry.js": `import { outer } from './deep.js';
console.log(outer(42));`,
      },
      "entry.js",
    );
    cleanup = r.cleanup;
    expect(r.runStderr).not.toContain("Maximum call stack");
    expect(r.runStderr).not.toContain("ReferenceError");
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("data:42");
  });

  test.concurrent("partial collision: shadowed member uses ns access, others stay inlined", async () => {
    const r = await bundleAndRun(
      {
        "data.js": `export function shadowed(x) { return "shadow:" + x; }
export function safeOne(x) { return "s1:" + x; }
export function safeTwo(x) { return "s2:" + x; }`,
        "user.js": `import * as M from './data.js';
export function compute() {
  const shadowed = (i) => M.shadowed(i);
  return shadowed(1) + "/" + M.safeOne(2) + "/" + M.safeTwo(3);
}`,
        "entry.js": `import { compute } from './user.js';
console.log(compute());`,
      },
      "entry.js",
    );
    cleanup = r.cleanup;
    expect(r.runStderr).not.toContain("Maximum call stack");
    expect(r.runStderr).not.toContain("ReferenceError");
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("shadow:1/s1:2/s2:3");
  });

  test.concurrent("function parameter shadows namespace member", async () => {
    const r = await bundleAndRun(
      {
        "lib.js": `export function process(x) { return "p:" + x; }`,
        "user.js": `import * as Lib from './lib.js';
export function run(process) {
  return Lib.process(process);
}`,
        "entry.js": `import { run } from './user.js';
console.log(run(99));`,
      },
      "entry.js",
    );
    cleanup = r.cleanup;
    expect(r.runStderr).not.toContain("Maximum call stack");
    expect(r.runStderr).not.toContain("ReferenceError");
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("p:99");
  });

  // #1928: `export * as NsA from './data.js'` used to emit the full inline getter object
  // at every access site AND tree-shake away the source statements (ReferenceError).
  // Fix: collectExportsRecursive records ns_target_mod; registerNamespaceRewrites hoists
  // a single `var NsA_ns = {...};` to the preamble; tryMarkReExportNsSubset recognizes
  // namespace consumers and falls back to markAllExportsUsed.
  test("re-export namespace barrel: Lib.NsA.x must reach the original", async () => {
    const r = await bundleAndRun(
      {
        "data.js": `export const a01 = () => "a01";
export const setSelectedLog = (i) => "log:" + i;`,
        "barrel.js": `export * as NsA from './data.js';`,
        "entry.js": `import * as Lib from './barrel.js';
console.log(Lib.NsA.a01() + "/" + Lib.NsA.setSelectedLog(7));`,
      },
      "entry.js",
    );
    cleanup = r.cleanup;
    expect(r.runStderr).not.toContain("ReferenceError");
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("a01/log:7");
  });

  test("re-export barrel: hoist correctness across many accesses", async () => {
    const r = await bundleAndRun(
      {
        "data.js": `export const a = () => "A"; export const b = () => "B"; export const c = () => "C";`,
        "barrel.js": `export * as Ns from './data.js';`,
        "entry.js": `import * as Lib from './barrel.js';
console.log([Lib.Ns.a(), Lib.Ns.b(), Lib.Ns.c(), Lib.Ns.a(), Lib.Ns.b()].join("/"));`,
      },
      "entry.js",
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("A/B/C/A/B");
  });

  test("multiple importers of the same barrel: each gets its own hoist (no cross-importer leak)", async () => {
    const r = await bundleAndRun(
      {
        "data.js": `export const greet = (n) => "hi " + n;`,
        "barrel.js": `export * as Ns from './data.js';`,
        "userA.js": `import * as Lib from './barrel.js';
export function callA() { return Lib.Ns.greet("A"); }`,
        "userB.js": `import * as Lib from './barrel.js';
export function callB() { return Lib.Ns.greet("B"); }`,
        "entry.js": `import { callA } from './userA.js';
import { callB } from './userB.js';
console.log(callA() + "/" + callB());`,
      },
      "entry.js",
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("hi A/hi B");
  });

  test("multiple namespace value importers share one namespace object (#1938)", async () => {
    const fixture = await createFixture({
      "core.js": `export const a = "a";
export const b = "b";`,
      "userA.js": `import * as Core from './core.js';
export const fa = () => Object.keys(Core).join(",");`,
      "userB.js": `import * as Core from './core.js';
export const fb = () => Object.keys(Core).join(",");`,
      "entry.js": `import { fa } from './userA.js';
import { fb } from './userB.js';
console.log(fa() + "/" + fb());`,
    });
    cleanup = fixture.cleanup;
    const outFile = join(fixture.dir, "out.js");

    const bundle = await runZts(["--bundle", join(fixture.dir, "entry.js"), "--format=esm", "-o", outFile]);
    expect(bundle.exitCode).toBe(0);

    const run = await runNode(outFile);
    expect(run.stdout).toBe("a,b/a,b");

    const code = readFileSync(outFile, "utf8");
    expect(code.match(/var [A-Za-z_$][\w$]*_ns\s*=\s*\{get a\(\)/g)?.length ?? 0).toBe(1);
  });

  test("shared namespace vars are deconflicted for same basename sources", async () => {
    const fixture = await createFixture({
      "alpha/core.js": `export const value = "alpha";`,
      "beta/core.js": `export const value = "beta";`,
      "userA.js": `import * as Core from './alpha/core.js';
export const fa = () => Object.values(Core).join(",");`,
      "userB.js": `import * as Core from './beta/core.js';
export const fb = () => Object.values(Core).join(",");`,
      "entry.js": `import { fa } from './userA.js';
import { fb } from './userB.js';
console.log(fa() + "/" + fb());`,
    });
    cleanup = fixture.cleanup;
    const outFile = join(fixture.dir, "out.js");

    const bundle = await runZts(["--bundle", join(fixture.dir, "entry.js"), "--format=esm", "-o", outFile]);
    expect(bundle.exitCode).toBe(0);

    const run = await runNode(outFile);
    expect(run.stdout).toBe("alpha/beta");

    const code = readFileSync(outFile, "utf8");
    const names = [...code.matchAll(/var ([A-Za-z_$][\w$]*_ns(?:_\d+)?)\s*=\s*\{get value\(\)/g)].map(
      (m) => m[1],
    );
    expect(names.length).toBe(2);
    expect(new Set(names).size).toBe(2);
  });

  test("nested re-export chain: outer barrel re-exports inner barrel re-exports data", async () => {
    const r = await bundleAndRun(
      {
        "data.js": `export const v = () => 42;`,
        "inner.js": `export * as Inner from './data.js';`,
        "outer.js": `export * from './inner.js';`,
        "entry.js": `import * as Lib from './outer.js';
console.log(Lib.Inner.v());`,
      },
      "entry.js",
    );
    cleanup = r.cleanup;
    expect(r.runStderr).not.toContain("ReferenceError");
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("42");
  });

  test("ns_var name does not collide with an exported identifier of the same prefix", async () => {
    const r = await bundleAndRun(
      {
        "data.js": `export const v = () => "data.v";`,
        // export name `Ns` exists alongside re-exported namespace also named `Ns_ns` —
        // makeUniqueNsVarName must pick a non-colliding name.
        "barrel.js": `export const Ns_ns = "exported_string";
export * as Ns from './data.js';`,
        "entry.js": `import * as Lib from './barrel.js';
console.log(Lib.Ns_ns + "|" + Lib.Ns.v());`,
      },
      "entry.js",
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("exported_string|data.v");
  });

  test("local export of namespace import: import * as X; export {X}", async () => {
    const r = await bundleAndRun(
      {
        "data.js": `export const k = () => "k";`,
        "wrap.js": `import * as Inner from './data.js';
export { Inner };`,
        "entry.js": `import * as W from './wrap.js';
console.log(W.Inner.k());`,
      },
      "entry.js",
    );
    cleanup = r.cleanup;
    expect(r.runStderr).not.toContain("ReferenceError");
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("k");
  });

  test("re-export ns + nested binding shadow on same barrel access", async () => {
    const r = await bundleAndRun(
      {
        "data.js": `export const fn = () => "data.fn"; export const other = () => "data.other";`,
        "barrel.js": `export * as Ns from './data.js';`,
        "user.js": `import * as Lib from './barrel.js';
export function compute() {
  // local 'fn' shadows nothing relevant — but Ns is still hoisted, and Lib.Ns.fn must work.
  const fn = (i) => "shadow:" + Lib.Ns.fn() + ":" + i;
  return fn(7) + "|" + Lib.Ns.other();
}`,
        "entry.js": `import { compute } from './user.js';
console.log(compute());`,
      },
      "entry.js",
    );
    cleanup = r.cleanup;
    expect(r.runStderr).not.toContain("Maximum call stack");
    expect(r.runStderr).not.toContain("ReferenceError");
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("shadow:data.fn:7|data.other");
  });

  test("namespace member chain depth 3: Lib.Outer.Inner.x", async () => {
    const r = await bundleAndRun(
      {
        "data.js": `export const x = () => "deep";`,
        "inner.js": `export * as Inner from './data.js';`,
        "outer.js": `export * as Outer from './inner.js';`,
        "entry.js": `import * as Lib from './outer.js';
console.log(Lib.Outer.Inner.x());`,
      },
      "entry.js",
    );
    cleanup = r.cleanup;
    expect(r.runStderr).not.toContain("ReferenceError");
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("deep");
  });

  test("only one member of barrel used → unused exports may still be tree-shaken if precision allows", async () => {
    const r = await bundleAndRun(
      {
        "data.js": `export const used = () => "used";
export const unused = () => "unused";`,
        "barrel.js": `export * as Ns from './data.js';`,
        // Direct named import path (precision should work).
        "entry.js": `import { Ns } from './barrel.js';
console.log(Ns.used());`,
      },
      "entry.js",
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("used");
  });
});
