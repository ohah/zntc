import { describe, test, expect, afterEach } from "bun:test";
import { bundleAndRun } from "./helpers";

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

  // Tracked by https://github.com/ohah/zts/issues/1928 — `export * as NsA from './data.js'`
  // currently emits the entire data.js exports as an inline getter object literal at every
  // member access site, and the source module statements get tree-shaken away, leaving the
  // getters dangling (`ReferenceError: a01 is not defined`). Fix lives in a follow-up PR.
  test.skip("re-export namespace barrel: Lib.NsA.x must reach the original", async () => {
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
});
