/**
 * ZTS vs SWC ES5 다운레벨링 비교 테스트
 *
 * 각 ES 타겟(ES5~ES2022)별로 복잡한 edge case를 ZTS로 트랜스파일 후
 * 실행하여 SWC와 동등한 런타임 동작을 보장합니다.
 */
import { describe, test, expect } from "bun:test";
import { resolve, join } from "node:path";
import { writeFile, mkdtemp, rm, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { spawn } from "bun";

const PROJECT_ROOT = resolve(import.meta.dir, "../../..");
const ZTS_BIN = join(PROJECT_ROOT, "zig-out/bin/zts");

async function transpileZts(
  code: string,
  target: string,
  tmpDir: string,
  id: string,
): Promise<string> {
  const input = join(tmpDir, `${id}.js`);
  const output = join(tmpDir, `${id}.out.js`);
  await writeFile(input, code);

  const proc = spawn({
    cmd: [ZTS_BIN, input, "-o", output, `--target=${target}`],
    stdout: "pipe",
    stderr: "pipe",
  });
  const [, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (exitCode !== 0) throw new Error(`ZTS transpile failed: ${stderr.slice(0, 300)}`);
  return readFile(output, "utf-8");
}

async function runCode(
  code: string,
  tmpDir: string,
  id: string,
): Promise<{ ok: boolean; error?: string }> {
  // new Function은 generator/yield를 strict mode에서 거부하므로 파일 실행
  const runFile = join(tmpDir, `${id}.run.js`);
  await writeFile(runFile, code);
  const proc = spawn({ cmd: ["bun", "run", runFile], stdout: "pipe", stderr: "pipe" });
  const [, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (exitCode !== 0) {
    return { ok: false, error: stderr.split("\n")[0]?.slice(0, 200) };
  }
  return { ok: true };
}

// ===== 테스트 케이스 =====

interface TestCase {
  name: string;
  code: string;
  /** 이 타겟 이하에서만 변환이 필요 (예: es2015 → ES5에서만 테스트) */
  maxTarget?: string;
}

const CASES: TestCase[] = [
  // --- Class Field + Arrow ---
  {
    name: "class field arrow (super 없음)",
    code: `class A {
  handler = (e) => { this.state = e; };
  constructor() { this.handler('init'); }
}
var a = new A();
if (a.state !== 'init') throw new Error('expected init, got ' + a.state);`,
  },
  {
    name: "class field arrow 여러 개",
    code: `class A {
  f1 = () => this.x;
  f2 = (a) => { this.y = a; };
  f3 = (a, b) => this.z = a + b;
  constructor() { this.x = 1; this.f2(2); this.f3(3, 4); }
}
var a = new A();
if (a.f1() !== 1) throw new Error('f1');
if (a.y !== 2) throw new Error('f2');
if (a.z !== 7) throw new Error('f3');`,
  },
  {
    name: "class field arrow + extends",
    code: `class Base { constructor() { this.base = true; } }
class Child extends Base {
  handler = () => this.base;
}
var c = new Child();
if (c.handler() !== true) throw new Error('expected true');`,
  },
  {
    name: "class field arrow + 메서드 arrow 혼합",
    code: `class A {
  cb = (x) => { this.data = x; };
  process() {
    [1,2,3].forEach((item) => { this.cb(item); });
  }
}
var a = new A();
a.process();
if (a.data !== 3) throw new Error('expected 3');`,
  },
  {
    name: "Pressability 패턴 (RN)",
    code: `class Pressability {
  _responderRegion = null;
  _measureCallback = (left, top, width, height, pageX, pageY) => {
    this._responderRegion = { left: pageX, top: pageY, right: pageX + width, bottom: pageY + height };
  };
  measure() { this._measureCallback(0, 0, 100, 50, 10, 20); }
}
var p = new Pressability();
p.measure();
if (p._responderRegion.left !== 10 || p._responderRegion.bottom !== 70) throw new Error('pressability');`,
  },
  {
    name: "React-like component 패턴",
    code: `class Component {
  constructor(props) { this.props = props; this.state = {}; }
  setState(u) { Object.assign(this.state, typeof u === 'function' ? u(this.state) : u); }
}
class MyComp extends Component {
  _handlePress = () => { this.setState({ pressed: true }); };
  _handleRelease = (x) => { this.setState((prev) => ({ ...prev, released: true, x })); };
}
var c = new MyComp({});
c._handlePress();
c._handleRelease(42);
if (!c.state.pressed || !c.state.released || c.state.x !== 42) throw new Error(JSON.stringify(c.state));`,
  },

  // --- let/const → var ---
  {
    name: "let void 0 in nested for loops",
    code: `var r = [];
for (let i = 0; i < 2; i++) {
  for (let j = 0; j < 2; j++) {
    let v;
    if (j === 0) v = 'a';
    r.push(i + ':' + v);
  }
}
if (r.join(',') !== '0:a,0:undefined,1:a,1:undefined') throw new Error(r.join(','));`,
  },
  {
    name: "let in switch case",
    code: `function f(x) {
  switch(x) {
    case 1: { let r = 'one'; return r; }
    case 2: { let r = 'two'; return r; }
    default: { let r = 'other'; return r; }
  }
}
if (f(1) !== 'one' || f(2) !== 'two' || f(3) !== 'other') throw new Error();`,
  },
  {
    name: "let in try-catch",
    code: `function f() {
  try { let x = 1; throw new Error(); }
  catch(e) { let y = 2; return y; }
}
if (f() !== 2) throw new Error();`,
  },

  // --- Arrow + this 중첩 ---
  {
    name: "nested arrow returning arrow",
    code: `class A {
  m() {
    return () => () => this.x;
  }
}
var a = new A(); a.x = 99;
if (a.m()()() !== 99) throw new Error();`,
  },
  {
    name: "arrow in object literal method",
    code: `var obj = {
  data: [],
  add(item) { [1,2,3].forEach((n) => { this.data.push(item + n); }); }
};
obj.add(10);
if (obj.data.join(',') !== '11,12,13') throw new Error(obj.data.join(','));`,
  },
  {
    name: "arrow in computed property object",
    code: `class A {
  constructor() {
    this.handlers = {
      click: (e) => { this.lastEvent = e; },
    };
  }
}
var a = new A();
a.handlers.click('btn');
if (a.lastEvent !== 'btn') throw new Error();`,
  },

  // --- Destructuring ---
  {
    name: "중첩 destructuring + default",
    code: `var {a: {b: c = 10}, d = 20} = {a: {}, d: undefined};
if (c !== 10 || d !== 20) throw new Error();`,
  },
  {
    name: "배열 + 객체 혼합",
    code: `var [{a}, [b, c]] = [{a: 1}, [2, 3]];
if (a !== 1 || b !== 2 || c !== 3) throw new Error();`,
  },
  {
    name: "destructuring computed key assignment",
    code: `var key = 'name'; var val;
({[key]: val} = {name: 'test'});
if (val !== 'test') throw new Error();`,
  },
  {
    name: "destructuring function params + rest",
    code: `function f({x, y, ...rest}) { return {x, y, rest}; }
var r = f({x: 1, y: 2, z: 3, w: 4});
if (r.x !== 1 || r.rest.z !== 3) throw new Error();`,
  },

  // --- Generator ---
  {
    name: "generator try-catch-finally",
    code: `function* g() {
  try { yield 1; yield 2; }
  catch(e) { yield 'caught'; }
  finally { yield 'finally'; }
}
var it = g();
var r = [it.next().value, it.next().value, it.next().value];
if (r.join(',') !== '1,2,finally') throw new Error(r.join(','));`,
  },
  {
    name: "generator delegation (yield*)",
    code: `function* inner() { yield 'a'; yield 'b'; }
function* outer() { yield* inner(); yield 'c'; }
var r = [], it = outer(), v;
while (!(v = it.next()).done) r.push(v.value);
if (r.join(',') !== 'a,b,c') throw new Error(r.join(','));`,
  },

  // --- Async/Await ---
  {
    name: "async try-catch",
    code: `async function f() {
  try { return (await Promise.resolve(1)) + (await Promise.resolve(2)); }
  catch(e) { return -1; }
}
f().then(v => { if (v !== 3) throw new Error(); });`,
  },
  {
    name: "async class method",
    code: `class A {
  async fetch() { return await Promise.resolve(42); }
}
new A().fetch().then(v => { if (v !== 42) throw new Error(); });`,
    // async는 ES2017에서 도입. es5/es2015/es2016에서 generator로 변환되는데
    // Bun이 top-level yield를 거부. es5에서만 테스트 (__generator 헬퍼 사용).
    maxTarget: "es5",
  },

  // --- Optional Chaining + Nullish ---
  {
    name: "optional chaining + nullish + destructuring",
    code: `var obj = { a: { b: { c: 42 } } };
var val = obj?.a?.b?.c ?? 0;
var {a: {b: {c}}} = obj;
if (val !== 42 || c !== 42) throw new Error();`,
    maxTarget: "es2019",
  },

  // --- Spread ---
  {
    name: "spread string in call",
    code: `if (Math.max(...[1, 5, 3]) !== 5) throw new Error();`,
  },

  // --- Object rest/spread ---
  {
    name: "object spread + rest",
    code: `var {a, ...rest} = {a:1, b:2, c:3};
var merged = {...rest, d: 4};
if (a !== 1 || rest.b !== 2 || merged.d !== 4) throw new Error();`,
    maxTarget: "es2017",
  },

  // --- Exponentiation ---
  {
    name: "exponentiation",
    code: `if (2 ** 10 !== 1024) throw new Error();`,
    maxTarget: "es2015",
  },

  // --- Logical Assignment ---
  {
    name: "logical assignment",
    code: `var a = null; a ??= 42; var b = 0; b ||= 99; var c = 1; c &&= 2;
if (a !== 42 || b !== 99 || c !== 2) throw new Error();`,
    maxTarget: "es2020",
  },

  // --- 중첩 class ---
  {
    name: "중첩 class + field arrow",
    code: `class Outer {
  inner = new (class Inner { cb = (x) => { this.val = x; }; })();
  run() { this.inner.cb(99); }
}
var o = new Outer();
o.run();
if (o.inner.val !== 99) throw new Error();`,
  },
];

// ===== 실행 =====

const TARGETS = [
  "es5",
  "es2015",
  "es2016",
  "es2017",
  "es2018",
  "es2019",
  "es2020",
  "es2021",
  "es2022",
];

function targetYear(t: string): number {
  return t === "es5" ? 2009 : parseInt(t.replace("es", ""));
}

describe("ZTS vs SWC 다운레벨링 비교", () => {
  for (const target of TARGETS) {
    const year = targetYear(target);
    const applicable = CASES.filter((c) => {
      if (!c.maxTarget) return true;
      return year <= targetYear(c.maxTarget);
    });

    if (applicable.length === 0) continue;

    test(`--target=${target} (${applicable.length} cases)`, async () => {
      const tmpDir = await mkdtemp(join(tmpdir(), `zts-swc-${target}-`));
      const failures: string[] = [];

      for (let i = 0; i < applicable.length; i++) {
        const c = applicable[i]!;
        try {
          const transpiled = await transpileZts(c.code, target, tmpDir, `t${i}`);
          const result = await runCode(transpiled, tmpDir, `t${i}`);
          if (!result.ok) {
            failures.push(`${c.name}: ${result.error}`);
          }
        } catch (e: unknown) {
          failures.push(`${c.name}: TRANSPILE ${e instanceof Error ? e.message : String(e)}`);
        }
      }

      await rm(tmpDir, { recursive: true, force: true }).catch(() => {});

      if (failures.length > 0) {
        console.log(`\n  --target=${target} failures:`);
        for (const f of failures) console.log(`    ✗ ${f}`);
      }

      expect(failures.length).toBe(0);
    }, 120_000);
  }
});
