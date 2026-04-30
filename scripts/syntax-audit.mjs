#!/usr/bin/env node
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const zts = join(root, "zig-out/bin/zts");
const tmp = mkdtempSync(join(tmpdir(), "zts-syntax-audit-"));

const singleFileCases = [
  {
    name: "default-param-tdz-and-order",
    code: `
const events = [];
function mark(v) { events.push(v); return v; }
function f(a = mark("a"), b = a + mark("b")) { return [a, b, events.join("")]; }
try { function g(a = b, b = 1) { return a + b; } g(); } catch (e) { events.push(e.name); }
console.log(JSON.stringify([f(1), f(), events]));
`,
  },
  {
    name: "destructuring-iterator-close",
    code: `
let log = [];
const iter = {
  [Symbol.iterator]() {
    let i = 0;
    return {
      next() { log.push("n" + i); return { value: i++, done: i > 4 }; },
      return() { log.push("return"); return { done: true }; },
    };
  },
};
const [a, b] = iter;
console.log(JSON.stringify({ a, b, log }));
`,
  },
  {
    name: "computed-key-single-eval",
    code: `
let i = 0;
const key = () => "k" + ++i;
const obj = { [key()]: 1, [key()]: 2 };
obj[key()] = (obj[key()] ?? 3) + 4;
console.log(JSON.stringify({ keys: Object.keys(obj), values: Object.values(obj), i }));
`,
  },
  {
    name: "optional-call-this-binding",
    code: `
const box = {
  value: 41,
  get nested() {
    return { value: this.value + 1, inc() { return this.value + 1; } };
  },
};
const missing = null;
console.log(JSON.stringify([box.nested?.inc?.(), missing?.nested?.inc?.()]));
`,
  },
  {
    name: "logical-assignment-receiver",
    code: `
const log = [];
const obj = {
  _x: 0,
  get x() { log.push("get:" + this._x); return this._x; },
  set x(v) { log.push("set:" + v); this._x = v; },
};
obj.x ||= 2;
obj.x &&= 3;
obj.x ??= 4;
console.log(JSON.stringify({ x: obj.x, log }));
`,
  },
  {
    name: "logical-assignment-super-computed-get-set",
    code: `
const log = [];
class Base {
  get x() { log.push("base.get:" + this.v); return this.v; }
  set x(v) { log.push("base.set:" + v + ":" + this.name); this.v = v; }
}
class Child extends Base {
  name = "child";
  v = 0;
  run(k) {
    super[k] ||= 5;
    super[k] &&= 7;
    super[k] ??= 9;
    return [this.v, log];
  }
}
console.log(JSON.stringify(new Child().run("x")));
`,
  },
  {
    name: "class-super-receiver",
    code: `
class Base {
  get x() { return this.tag + ":get"; }
  set x(v) { this.log.push(this.tag + ":" + v); }
  m(v) { return this.tag + ":" + v; }
}
class Child extends Base {
  tag = "child";
  log = [];
  run(k) {
    super.x = super.m(super.x + ":" + k);
    return this.log[0];
  }
}
console.log(JSON.stringify(new Child().run("ok")));
`,
  },
  {
    name: "derived-constructor-return-order",
    code: `
const log = [];
class Base { constructor(v) { log.push("base:" + v); this.v = v; } }
class Child extends Base {
  field = log.push("field:" + this.v);
  constructor() {
    log.push("before");
    const result = super(log.push("arg"));
    log.push("after:" + (result === this));
  }
}
new Child();
console.log(JSON.stringify(log));
`,
  },
  {
    name: "derived-constructor-return-expression-super-fields",
    code: `
const log = [];
class Base { constructor(v) { log.push("base:" + v); this.v = v; } }
class Child extends Base {
  a = log.push("a:" + this.v);
  constructor(flag) {
    log.push("before");
    return flag ? (log.push("ret"), super(3)) : super(4);
  }
}
new Child(true);
console.log(JSON.stringify(log));
`,
  },
  {
    name: "private-field-brand-and-update",
    code: `
class Counter {
  #value = 1;
  static has(x) { return #value in x; }
  bump() { return [this.#value++, ++this.#value, this.#value]; }
}
const c = new Counter();
console.log(JSON.stringify([Counter.has(c), Counter.has({}), c.bump()]));
`,
  },
  {
    name: "static-block-order",
    code: `
const log = [];
class A {
  static a = log.push("a");
  static { log.push("block:" + this.a); }
  static b = log.push("b");
}
console.log(JSON.stringify([A.a, A.b, log]));
`,
  },
  {
    name: "static-private-and-public-order",
    code: `
const log = [];
class A {
  static #x = log.push("priv");
  static a = log.push("a:" + this.#x);
  static { log.push("block:" + this.a); }
  static b = log.push("b:" + this.#x);
  static read() { return [this.#x, this.a, this.b, log]; }
}
console.log(JSON.stringify(A.read()));
`,
  },
  {
    name: "static-computed-key-order-with-blocks",
    code: `
const log = [];
let i = 0;
function key(label) { log.push("key:" + label + ":" + ++i); return label + i; }
class A {
  static [key("a")] = log.push("fieldA");
  static { log.push("block:" + Object.keys(this).join(",")); }
  static [key("b")] = log.push("fieldB");
}
console.log(JSON.stringify([Object.keys(A), log]));
`,
  },
  {
    name: "tagged-template-identity-and-raw",
    code: `
const seen = new WeakSet();
function tag(strings, value) {
  const first = seen.has(strings);
  seen.add(strings);
  return [first, strings.raw[0], strings[0], value].join("|");
}
console.log(JSON.stringify([tag\`a\\nb\${1}\`, tag\`a\\nb\${2}\`]));
`,
  },
  {
    name: "async-generator-finally",
    code: `
async function* gen() {
  try {
    yield 1;
    yield await Promise.resolve(2);
  } finally {
    yield 3;
  }
}
(async () => {
  const out = [];
  for await (const v of gen()) {
    out.push(v);
    if (v === 2) break;
  }
console.log(JSON.stringify(out));
})();
`,
  },
  {
    name: "async-generator-throw-finally-yield",
    code: `
async function* gen() {
  try {
    yield 1;
  } finally {
    yield 2;
  }
}
(async () => {
  const it = gen();
  const out = [];
  out.push(await it.next());
  try { out.push(await it.throw(new Error("boom"))); } catch (e) { out.push("caught:" + e.message); }
  try { out.push(await it.next()); } catch (e) { out.push("next-caught:" + e.message); }
  console.log(JSON.stringify(out));
})();
`,
  },
  {
    name: "object-rest-computed-eval-order",
    code: `
const log = [];
const src = { a: 1, b: 2, c: 3 };
function k() { log.push("key"); return "b"; }
const { [k()]: picked, ...rest } = src;
console.log(JSON.stringify({ picked, rest, log }));
`,
  },
  {
    name: "for-of-let-closure-continue",
    code: `
const fns = [];
for (let x of [1, 2, 3, 4]) {
  if (x % 2) continue;
  fns.push(() => x);
}
console.log(JSON.stringify(fns.map((fn) => fn())));
`,
  },
];

const bundleCases = [
  {
    name: "live-binding-reexport",
    files: {
      "entry.mjs": `
import { value, inc } from "./barrel.mjs";
console.log(JSON.stringify([value, inc(), value, inc(), value]));
`,
      "barrel.mjs": `export { value, inc } from "./state.mjs";`,
      "state.mjs": `
export let value = 0;
export function inc() {
  value += 1;
  return value;
}
`,
    },
  },
  {
    name: "cycle-function-before-value",
    files: {
      "entry.mjs": `
import { fromA } from "./a.mjs";
console.log(JSON.stringify(fromA()));
`,
      "a.mjs": `
import { b, callB } from "./b.mjs";
export const a = "a";
export function fromA() { return ["fromA", b, callB()]; }
`,
      "b.mjs": `
import { a } from "./a.mjs";
export const b = "b";
export function callB() { return ["callB", a]; }
`,
    },
  },
  {
    name: "dynamic-import-namespace",
    files: {
      "entry.mjs": `
const ns1 = await import("./lazy.mjs");
const ns2 = await import("./lazy.mjs");
console.log(JSON.stringify([ns1 === ns2, ns1.default, ns1.named]));
`,
      "lazy.mjs": `
export const named = 7;
export default named + 1;
`,
    },
  },
  {
    name: "namespace-dynamic-key",
    files: {
      "entry.mjs": `
import * as ns from "./mod.mjs";
const k = "beta";
console.log(JSON.stringify([Object.keys(ns).sort(), ns[k], ns.alpha]));
`,
      "mod.mjs": `
export const alpha = 1;
export const beta = 2;
`,
    },
  },
];

function run(cmd, args, options = {}) {
  const result = spawnSync(cmd, args, {
    cwd: options.cwd ?? root,
    encoding: "utf8",
    timeout: options.timeout ?? 10000,
  });
  return {
    ok: result.status === 0,
    status: result.status,
    stdout: result.stdout.trimEnd(),
    stderr: result.stderr.trimEnd(),
  };
}

function write(path, content) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
}

function fail(label, details) {
  console.error(`\nFAIL ${label}`);
  console.error(details);
  process.exitCode = 1;
}

function assertEqual(label, actual, expected, extra = "") {
  if (actual !== expected) {
    fail(label, `expected: ${expected}\nactual:   ${actual}${extra ? `\n${extra}` : ""}`);
  }
}

try {
  console.log(`syntax audit temp: ${tmp}`);

  for (const test of singleFileCases) {
    const dir = join(tmp, "single", test.name);
    const input = join(dir, "input.mjs");
    write(input, test.code);

    const native = run("node", [input]);
    if (!native.ok) {
      fail(`${test.name}: native`, native.stderr || native.stdout);
      continue;
    }

    for (const target of ["es5", "es2015", "es2019", "es2022"]) {
      const out = join(dir, `zts-${target}.mjs`);
      const built = run(zts, [input, "--target=" + target, "--format=esm", "-o", out]);
      if (!built.ok) {
        fail(`${test.name}: transpile ${target}`, built.stderr || built.stdout);
        continue;
      }
      const checked = run("node", ["--check", out]);
      if (!checked.ok) {
        fail(`${test.name}: syntax ${target}`, checked.stderr || checked.stdout);
        continue;
      }
      const actual = run("node", [out]);
      if (!actual.ok) {
        fail(`${test.name}: run ${target}`, actual.stderr || actual.stdout);
        continue;
      }
      assertEqual(`${test.name}: ${target}`, actual.stdout, native.stdout);
    }
    console.log(`ok single ${test.name}`);
  }

  for (const test of bundleCases) {
    const dir = join(tmp, "bundle", test.name);
    for (const [name, content] of Object.entries(test.files)) {
      write(join(dir, name), content);
    }
    const entry = join(dir, "entry.mjs");
    const native = run("node", [entry]);
    if (!native.ok) {
      fail(`${test.name}: native`, native.stderr || native.stdout);
      continue;
    }

    for (const target of ["es5", "es2015", "es2022"]) {
      const out = join(dir, `bundle-${target}.mjs`);
      const built = run(zts, ["--bundle", entry, "--target=" + target, "--format=esm", "-o", out]);
      if (!built.ok) {
        fail(`${test.name}: bundle ${target}`, built.stderr || built.stdout);
        continue;
      }
      const checked = run("node", ["--check", out]);
      if (!checked.ok) {
        fail(`${test.name}: bundle syntax ${target}`, checked.stderr || checked.stdout);
        continue;
      }
      const actual = run("node", [out]);
      if (!actual.ok) {
        fail(`${test.name}: bundle run ${target}`, actual.stderr || actual.stdout);
        continue;
      }
      assertEqual(
        `${test.name}: bundle ${target}`,
        actual.stdout,
        native.stdout,
        readFileSync(out, "utf8").slice(0, 500),
      );
    }
    console.log(`ok bundle ${test.name}`);
  }
} finally {
  if (process.exitCode) {
    console.error(`kept failing temp dir: ${tmp}`);
  } else {
    rmSync(tmp, { recursive: true, force: true });
  }
}
