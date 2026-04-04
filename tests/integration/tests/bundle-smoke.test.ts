import { describe, test, expect, afterEach } from "bun:test";
import { bundleAndRun, runZts, runZtsInDir, createFixture, ZTS_BIN } from "./helpers";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

describe("ZTS CLI", () => {
  test("바이너리가 존재한다", () => {
    expect(existsSync(ZTS_BIN)).toBe(true);
  });

  test("--help 플래그가 동작한다", async () => {
    const { exitCode, stdout } = await runZts(["--help"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("Usage");
  });
});

describe("번들 스모크 테스트", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("단일 파일 번들", async () => {
    const result = await bundleAndRun({
      "index.ts": `const msg: string = "hello"; console.log(msg);`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("hello");
  });

  test("다중 파일 import", async () => {
    const result = await bundleAndRun({
      "index.ts": `import { add } from "./math"; console.log(add(1, 2));`,
      "math.ts": `export function add(a: number, b: number): number { return a + b; }`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("3");
  });

  test("TS 타입 스트리핑", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        interface User { name: string; age: number; }
        const user: User = { name: "test", age: 25 };
        console.log(user.name);
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("test");
  });

  test("forward reference — 같은 이름 변수의 올바른 참조", async () => {
    // 두 모듈이 같은 이름의 top-level 변수(helper)를 갖고,
    // forward reference(helper가 greet보다 뒤에 선언)가 있을 때
    // scope hoisting 후 각 greet이 자기 모듈의 helper를 호출해야 한다.
    const result = await bundleAndRun({
      "index.ts": `import { greet as a } from "./a"; import { greet as b } from "./b"; console.log(a(), b());`,
      "a.ts": `export const greet = () => helper(); export const helper = () => "from_a";`,
      "b.ts": `export const greet = () => helper(); export const helper = () => "from_b";`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("from_a from_b");
  });

  test("abstract 멤버 스트리핑", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        abstract class BaseService {
          abstract getName(): string;
          abstract readonly id: number;
          greet() { return "Hello, " + this.getName(); }
        }
        class UserService extends BaseService {
          getName() { return "User"; }
          get id() { return 1; }
        }
        console.log(new UserService().greet());
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("Hello, User");
    expect(result.bundleOutput).not.toContain("abstract");
  });

  test("declare 필드 스트리핑", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        class Config {
          declare env: string;
          declare readonly debug: boolean;
          host = "localhost";
          port = 3000;
        }
        const cfg = new Config();
        console.log(cfg.host + ":" + cfg.port);
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("localhost:3000");
    // declare 필드가 제거되어 env/debug가 undefined로 초기화되면 안 됨
    expect(result.bundleOutput).not.toContain("env");
    expect(result.bundleOutput).not.toContain("debug");
  });

  test("abstract + declare 복합 — 실전 패턴", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        import { UserRepo } from "./repo";
        const repo = new UserRepo();
        console.log(repo.findAll().join(","));
      `,
      "repo.ts": `
        abstract class BaseRepo<T> {
          declare tableName: string;
          abstract findAll(): T[];
          count() { return this.findAll().length; }
        }
        export class UserRepo extends BaseRepo<string> {
          findAll() { return ["alice", "bob"]; }
        }
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("alice,bob");
  });

  test("tree-shaking으로 미사용 모듈 제거", async () => {
    const { dir, cleanup: c } = await createFixture({
      "index.ts": `import { used } from "./used"; console.log(used);`,
      "used.ts": `export const used = "yes";`,
      "unused.ts": `export const unused = "no";`,
    });
    cleanup = c;

    const outFile = join(dir, "out.js");
    const bundle = await runZts(["--bundle", join(dir, "index.ts"), "-o", outFile]);
    expect(bundle.exitCode).toBe(0);

    const output = await Bun.file(outFile).text();
    expect(output).toContain("yes");
    // 미사용 모듈은 번들에 포함되지 않아야 함
    expect(output).not.toContain("unused.ts");
  });

  test("서브패스 package.json resolve (디렉토리 내 main/module 필드)", async () => {
    // fp-ts 패턴: fp-ts/function → fp-ts/function/package.json → { "module": "../es6/function.js" }
    const result = await bundleAndRun({
      "index.ts": `import { add } from "./mylib/math"; console.log(add(1, 2));`,
      "mylib/math/package.json": `{ "main": "../src/math.js", "module": "../src/math.mjs" }`,
      "mylib/src/math.mjs": `export function add(a, b) { return a + b; }`,
      "mylib/src/math.js": `module.exports.add = function(a, b) { return a + b; };`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("3");
  });

  test("module 필드 resolve 시 .js를 ESM으로 파싱", async () => {
    // package.json "module" 필드가 가리키는 .js는 ESM이어야 함
    const result = await bundleAndRun({
      "index.ts": `import { greet } from "./pkg"; console.log(greet("world"));`,
      "pkg/package.json": `{ "main": "../lib/index.js", "module": "../esm/index.js" }`,
      "esm/index.js": `export function greet(name) { return "hello " + name; }`,
      "lib/index.js": `module.exports.greet = function(name) { return "hello " + name; };`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("hello world");
  });

  test("module 필드 ESM 전이 전파 (상대 import)", async () => {
    // module 필드 모듈에서 상대 경로로 import하는 .js도 ESM으로 파싱
    const result = await bundleAndRun({
      "index.ts": `import { double } from "./pkg"; console.log(double(21));`,
      "pkg/package.json": `{ "module": "../esm/index.js" }`,
      "esm/index.js": `import { multiply } from "./utils.js"; export function double(n) { return multiply(n, 2); }`,
      "esm/utils.js": `export function multiply(a, b) { return a * b; }`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("42");
  });

  test("namespace import 동적 접근 (import * as + obj[key])", async () => {
    const result = await bundleAndRun({
      "index.ts": `import * as lib from "./lib"; const k = "bar"; console.log(lib.foo(), lib[k]());`,
      "lib.ts": `export function foo() { return "foo"; } export function bar() { return "bar"; }`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("foo bar");
  });

  test("namespace import Object.keys (import * as)", async () => {
    const result = await bundleAndRun({
      "index.ts": `import * as lib from "./lib"; console.log(Object.keys(lib).sort().join(","));`,
      "lib.ts": `export const a = 1; export const b = 2; export const c = 3;`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("a,b,c");
  });

  test("namespace import + for loop 동적 접근", async () => {
    const result = await bundleAndRun({
      "index.ts": `import * as lib from "./lib"; const out: string[] = []; for (const k of Object.keys(lib)) { out.push(typeof (lib as any)[k]); } console.log(out.join(","));`,
      "lib.ts": `export function foo() {} export function bar() {} export const val = 42;`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("function,function,number");
  });

  test("namespace import 변수명 충돌 방지 (_ns suffix)", async () => {
    // z라는 이름이 내부에서 namespace import로 사용되고 re-export되는 패턴
    const result = await bundleAndRun({
      "index.ts": `import { z } from "./pkg"; console.log(z.foo());`,
      "pkg.ts": `import * as z from "./inner"; export { z };`,
      "inner.ts": `export function foo() { return "ok"; }`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("ok");
  });

  test("namespace 변수명 progressive 충돌 방지 (z_ns export 존재 시 z_ns2)", async () => {
    const result = await bundleAndRun({
      "index.ts": `import * as z from "./lib"; console.log(z.foo(), z.z_ns, Object.keys(z).sort().join(","));`,
      "lib.ts": `export function foo() { return "ok"; } export const z_ns = 42;`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("ok 42 foo,z_ns");
  });

  test("namespace 변수명 이중 충돌 (z_ns + z_ns2 export 존재 시 z_ns3)", async () => {
    const result = await bundleAndRun({
      "index.ts": `import * as z from "./lib"; console.log(z.foo(), z.z_ns, z.z_ns2, Object.keys(z).sort().join(","));`,
      "lib.ts": `export function foo() { return "ok"; } export const z_ns = 1; export const z_ns2 = 2;`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("ok 1 2 foo,z_ns,z_ns2");
  });

  test("namespace import 빈 모듈", async () => {
    const result = await bundleAndRun({
      "index.ts": `import * as empty from "./lib"; console.log(Object.keys(empty).length);`,
      "lib.ts": `// empty`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("0");
  });

  test("namespace import를 함수 인자로 전달", async () => {
    const result = await bundleAndRun({
      "index.ts": `import * as lib from "./lib"; function inspect(obj: any) { return Object.keys(obj).join(","); } console.log(inspect(lib));`,
      "lib.ts": `export const a = 1; export const b = 2;`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("a,b");
  });

  test("namespace를 변수에 대입", async () => {
    const result = await bundleAndRun({
      "index.ts": `import * as lib from "./lib"; const ref = lib; console.log(ref.foo());`,
      "lib.ts": `export function foo() { return "ok"; }`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("ok");
  });

  test("namespace를 typeof로 사용", async () => {
    const result = await bundleAndRun({
      "index.ts": `import * as lib from "./lib"; console.log(typeof lib);`,
      "lib.ts": `export const a = 1;`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("object");
  });

  test("namespace를 spread로 사용", async () => {
    const result = await bundleAndRun({
      "index.ts": `import * as lib from "./lib"; const copy = { ...lib }; console.log(copy.a, copy.b);`,
      "lib.ts": `export const a = 1; export const b = 2;`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("1 2");
  });

  // #445: shorthand property에서 rename된 식별자 (수정됨)
  test("shorthand property에서 rename된 식별자 (#445)", async () => {
    const result = await bundleAndRun({
      "index.ts": `import { defer } from './b'; import obj from './c'; console.log(obj.defer(), defer);`,
      "a.ts": `export default function defer() { return 'ok'; }`,
      "b.ts": `const defer = 'other'; export { defer };`,
      "c.ts": `import defer from './a'; export default { defer };`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("ok other");
  });

  test("import defer from — default import (not phase modifier)", async () => {
    const result = await bundleAndRun({
      "index.ts": `import defer from "./a"; console.log(defer);`,
      "a.ts": `export default 42;`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("42");
  });

  test("import source from — default import (not phase modifier)", async () => {
    const result = await bundleAndRun({
      "index.ts": `import source from "./a"; console.log(source);`,
      "a.ts": `export default 42;`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("42");
  });

  test("import defer, { x } from — defer as default + named import", async () => {
    const result = await bundleAndRun({
      "index.ts": `import defer, { x } from "./a"; console.log(defer, x);`,
      "a.ts": `export default 10; export const x = 20;`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("10 20");
  });

  test("shorthand rename — 여러 모듈에서 같은 이름 충돌", async () => {
    const result = await bundleAndRun({
      "index.ts": `import { x } from "./b"; import obj from "./c"; console.log(obj.x(), x());`,
      "a.ts": `export default function x() { return "a"; }`,
      "b.ts": `export function x() { return "b"; }`,
      "c.ts": `import x from "./a"; export default { x };`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("a b");
  });

  test("shorthand 중첩 scope — 내부 변수 shadowing 정확성", async () => {
    const result = await bundleAndRun({
      "index.ts": `const x = 'outer'; function inner() { const x = 'inner'; return { x }; } console.log(inner().x);`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("inner");
  });

  test("function source() — contextual keyword as function name", async () => {
    const result = await bundleAndRun({
      "index.ts": `import source from "./a"; console.log(source());`,
      "a.ts": `export default function source() { return "src"; }`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("src");
  });

  test("scope hoisting 내부 함수 shadowing 충돌 방지 (#450)", async () => {
    // d3 패턴: import {cubehelix as colorCubehelix} + 내부 function cubehelix
    const result = await bundleAndRun({
      "index.ts": `import { result } from "./interp"; console.log(result);`,
      "color.ts": `export function cubehelix(h: number) { return h * 2; }`,
      "interp.ts": `
        import { cubehelix as colorCubehelix } from "./color";
        function outer() {
          function cubehelix(start: number, end: number) {
            return colorCubehelix(start) + colorCubehelix(end);
          }
          return cubehelix;
        }
        export const result = outer()(1, 2);
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("6");
  });

  test("삼항 + 화살표 expression body 파싱 (#446)", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        function cumsum(values: number[], valueof?: (v: number, i: number) => number) {
          var sum = 0, index = 0;
          return Float64Array.from(values, valueof === undefined
            ? v => (sum += +v || 0)
            : v => (sum += +valueof(v, index++) || 0));
        }
        const r = cumsum([1, 2, 3]);
        console.log(Array.from(r).join(","));
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("1,3,6");
  });

  test("CJS import 변수명 scope 충돌 해결", async () => {
    // 두 모듈이 같은 이름(StyleSheet)을 top-level에 선언할 때
    // CJS preamble 변수와 ESM export가 충돌하지 않아야 함
    const result = await bundleAndRun(
      {
        "index.ts": `
          import { StyleSheet } from "./styles";
          import { render } from "./renderer";
          console.log(StyleSheet.create({}) + "," + render());
        `,
        "styles.ts": `
          export const StyleSheet = { create(s: any) { return "created"; } };
        `,
        "renderer.ts": `
          const StyleSheet = { flatten(s: any) { return "flat"; } };
          export function render() { return StyleSheet.flatten({}); }
        `,
      },
      "index.ts",
    );
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("created,flat");
  });

  test("CJS 래핑된 ESM 모듈의 import가 require_xxx()로 변환 — 번들 출력 검증", async () => {
    // ESM 모듈이 require()로 소비되어 __commonJS 래핑될 때,
    // 내부 import 문의 require()가 require_xxx()로 치환되어야 함.
    // raw require("specifier")가 남아있으면 런타임에서 require 미정의 에러 발생.
    const fixture = await createFixture({
      "index.ts": `const lib = require('./esm-lib.js'); console.log(lib.greet());`,
      "esm-lib.js": `
        import * as helper from './helper.cjs';
        export function greet() { return helper.default(); }
      `,
      "helper.cjs": `module.exports = function() { return 'hello-from-cjs'; };`,
    });
    cleanup = fixture.cleanup;
    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile]);
    expect(bundle.exitCode).toBe(0);

    const output = await Bun.file(outFile).text();
    // default import: require_helper()로 변환되어야 함
    expect(output).toContain("require_helper()");
    // raw require("./helper.cjs")가 남아있으면 안 됨
    expect(output).not.toContain('require("./helper.cjs")');
    expect(output).not.toContain("require('./helper.cjs')");
  });

  test("CJS 래핑된 ESM 모듈의 named import — 번들 출력 검증", async () => {
    const fixture = await createFixture({
      "index.ts": `const lib = require('./consumer.js'); console.log(lib.compute());`,
      "consumer.js": `
        import { multiply } from './math.cjs';
        export function compute() { return multiply(6, 7); }
      `,
      "math.cjs": `exports.multiply = function(a, b) { return a * b; };`,
    });
    cleanup = fixture.cleanup;
    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile]);
    expect(bundle.exitCode).toBe(0);

    const output = await Bun.file(outFile).text();
    expect(output).toContain("require_math()");
    expect(output).not.toContain('require("./math.cjs")');
    expect(output).not.toContain("require('./math.cjs')");
  });

  test("CJS 래핑된 ESM 모듈의 side-effect import — 번들 출력 검증", async () => {
    const fixture = await createFixture({
      "index.ts": `const lib = require('./app.js'); console.log(lib.value);`,
      "app.js": `
        import './setup.cjs';
        export const value = globalThis.__SETUP_DONE;
      `,
      "setup.cjs": `globalThis.__SETUP_DONE = 'setup-ok';`,
    });
    cleanup = fixture.cleanup;
    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile]);
    expect(bundle.exitCode).toBe(0);

    const output = await Bun.file(outFile).text();
    expect(output).toContain("require_setup()");
    expect(output).not.toContain('require("./setup.cjs")');
    expect(output).not.toContain("require('./setup.cjs')");
  });
});

describe("__esm 실행 순서 보장", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("호이스팅된 함수가 의존 모듈 초기화 후에 호출된다", async () => {
    // invariant.js → TurboModuleRegistry.js 패턴 재현:
    // registry.js가 util.js의 함수를 import하고,
    // registry.js의 호이스팅된 함수 안에서 그 함수를 호출한다.
    // consumer.js가 registry.js의 함수를 호출할 때,
    // util.js의 init이 먼저 실행되어야 한다.
    const result = await bundleAndRun({
      "index.ts": `
        import { getEnforcing } from "./registry";
        console.log(getEnforcing("test"));
      `,
      "registry.ts": `
        import { validate } from "./util";
        export function getEnforcing(name: string): string {
          validate(name);
          return "ok:" + name;
        }
      `,
      "util.ts": `
        export function validate(name: string): void {
          if (!name) throw new Error("name required");
        }
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("ok:test");
  });

  test("3단계 의존 체인에서 init 순서가 보장된다", async () => {
    // A → B → C 의존 체인: C의 변수가 B의 함수에서 사용되고,
    // A가 B의 함수를 호출할 때 C가 먼저 초기화되어야 한다.
    const result = await bundleAndRun({
      "index.ts": `
        import { run } from "./middle";
        console.log(run());
      `,
      "middle.ts": `
        import { getPrefix } from "./base";
        export function run(): string {
          return getPrefix() + ":done";
        }
      `,
      "base.ts": `
        const PREFIX = "init";
        export function getPrefix(): string {
          return PREFIX;
        }
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("init:done");
  });

  test("CJS 의존 모듈의 init이 __esm body에서 실행된다", async () => {
    // ESM 모듈이 CJS 모듈을 import하고, 호이스팅된 함수에서 사용
    const result = await bundleAndRun({
      "index.ts": `
        import { greet } from "./greeter";
        console.log(greet("world"));
      `,
      "greeter.ts": `
        import helper from "./helper.cjs";
        export function greet(name: string): string {
          return helper(name);
        }
      `,
      "helper.cjs": `
        module.exports = function(name) {
          return "hello " + name;
        };
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("hello world");
  });

  test("__esm→__esm: named import의 destructuring assignment 괄호", async () => {
    // ESM→ESM 양쪽 __esm 래핑 시 named import가 ({a}=expr) 형태여야 한다.
    // 괄호 없으면 {a}가 block으로 파싱되어 구문 에러(Hermes 등) 발생.
    const result = await bundleAndRun({
      "index.ts": `
        import { compute } from "./calc";
        import { VALUE } from "./consts";
        console.log(compute(), VALUE);
      `,
      "calc.ts": `
        import { VALUE } from "./consts";
        export function compute() { return "v:" + VALUE; }
      `,
      "consts.ts": `
        export const VALUE = 42;
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("v:42 42");
  });

  test("default+named 동시 import에서 named 괄호 처리", async () => {
    // import Foo, { Bar } from "./mod" → default+named 동시 패턴
    const result = await bundleAndRun({
      "index.ts": `
        import { result } from "./consumer";
        console.log(result());
      `,
      "consumer.ts": `
        import Provider, { helper } from "./provider";
        export function result() { return helper() + "+" + Provider(); }
      `,
      "provider.ts": `
        export default function Provider() { return "default"; }
        export function helper() { return "named"; }
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("named+default");
  });

  test("__esm body에서 init 호출 중복 없음", async () => {
    // __esm→__esm import 시 body에서 init이 중복되지 않아야 한다
    const { dir, cleanup: c } = await createFixture({
      "entry.cjs": `
        const { run } = require("./wrapper");
        const { VAL } = require("./dep");
        console.log(run(), VAL);
      `,
      "wrapper.ts": `
        import { VAL } from "./dep";
        export function run() { return "got:" + VAL; }
      `,
      "dep.ts": `
        export const VAL = "ok";
      `,
    });
    cleanup = c;
    const outFile = join(dir, "out.js");
    await runZts(["--bundle", join(dir, "entry.cjs"), "-o", outFile]);

    // wrapper의 __esm body에서 init_dep가 1회만 호출되는지 검증
    const output = await Bun.file(outFile).text();
    const wrapperEsm = output.match(/init_wrapper\s*=\s*__esm\(\{[\s\S]*?\}\s*\}\);/);
    expect(wrapperEsm).not.toBeNull();
    if (wrapperEsm) {
      const initCalls = (wrapperEsm[0].match(/init_dep\(\)/g) || []).length;
      expect(initCalls).toBe(1);
    }
  });

  test("__esm body에서 CJS import의 var 선언 없음", async () => {
    // __esm body 안에서 var 선언은 function scope에 갇히므로 할당만 있어야 한다
    const { dir, cleanup: c } = await createFixture({
      "entry.cjs": `
        const { greet } = require("./mod");
        console.log(greet());
      `,
      "mod.ts": `
        import msg from "./msg.cjs";
        export function greet() { return msg; }
      `,
      "msg.cjs": `
        module.exports = "hello";
      `,
    });
    cleanup = c;
    const outFile = join(dir, "out.js");
    await runZts(["--bundle", join(dir, "entry.cjs"), "-o", outFile]);

    const output = await Bun.file(outFile).text();
    const modEsm = output.match(/init_mod\s*=\s*__esm\(\{[\s\S]*?\}\s*\}\);/);
    expect(modEsm).not.toBeNull();
    if (modEsm) {
      // body 안에 "var " + require 패턴이 없어야 한다
      expect(modEsm[0]).not.toMatch(/var\s+\w+\s*=\s*.*require_/);
    }
  });

  test("__esm import binding rename — scope-hoisted 타겟과 이름 충돌", async () => {
    // ReactNativeFeatureFlags 패턴:
    // base.js가 createFlag를 export, flags.js가 import하여 사용
    // consumer.js가 require()로 flags.js를 소비 → flags.js가 __esm 래핑
    // base.js와 flags.js 모두 createFlag가 scope에 있어서 이름 충돌
    // → flags.js의 import binding이 잘못 rename되면 정의/참조 불일치
    const result = await bundleAndRun(
      {
        "index.ts": `
        import { getResult } from "./consumer.js";
        console.log(getResult());
      `,
        "consumer.js": `
        const flags = require("./flags.js");
        export function getResult() { return flags.testFlag(); }
      `,
        "base.js": `
        export function createFlag(name, defaultValue) {
          return () => defaultValue;
        }
      `,
        "flags.js": `
        import { createFlag } from "./base.js";
        export const testFlag = createFlag("test", "ok");
      `,
      },
      "index.ts",
      ["--format=cjs"],
    );
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("ok");
  });

  test("__esm import binding rename — 동일 함수명 두 모듈 충돌 (function hoisting)", async () => {
    // 두 모듈이 같은 이름의 함수를 export하고, 한쪽이 __esm 래핑되는 경우
    // function 선언은 __esm 밖으로 호이스팅되므로 rename이 정의에도 적용되어야 함
    const result = await bundleAndRun(
      {
        "index.ts": `
        import { getFlag as getA } from "./a.js";
        const b = require("./b.js");
        console.log(getA(), b.getFlag());
      `,
        "a.js": `
        export function getFlag() { return "a"; }
      `,
        "b.js": `
        import { createHelper } from "./helper.js";
        export function getFlag() { return createHelper("b"); }
      `,
        "helper.js": `
        export function createHelper(val) { return val; }
      `,
      },
      "index.ts",
      ["--format=cjs"],
    );
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("a b");
  });

  test("new expression with type arguments — new X<T>() 이중 호출 방지", async () => {
    // new WeakSet<{...}>() 같은 TS/Flow 제네릭이 new WeakSet()()로 잘못 변환되지 않아야 함
    const result = await bundleAndRun({
      "index.ts": `
        const s = new Set<number>();
        const m = new Map<string, number>();
        s.add(1); s.add(2);
        m.set("a", 10);
        console.log(s.size, m.get("a"));
      `,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("2 10");
  });

  test("__esm 모듈 정의가 scope-hoisted 호출보다 먼저 위치해야 함", async () => {
    // scope-hoisted 모듈이 __esm 모듈의 init_xxx()를 호출할 때,
    // var init_xxx = __esm({...}) 할당이 호출 지점보다 앞에 있어야 함
    const result = await bundleAndRun(
      {
        "index.ts": `
        import { result } from "./consumer.js";
        console.log(result);
      `,
        "consumer.js": `
        const lib = require("./lib.js");
        export const result = lib.getValue();
      `,
        "lib.js": `
        import { helper } from "./helper.js";
        export function getValue() { return helper(); }
      `,
        "helper.js": `
        export function helper() { return "ok"; }
      `,
      },
      "index.ts",
      ["--format=cjs"],
    );
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("ok");
  });

  // ============================================================
  // ES5 + rename: symbol_id 전파 회귀 테스트
  // ============================================================

  test("ES5 class rename — __extends와 prototype에 renamed 이름 사용", async () => {
    // 두 모듈에서 같은 이름의 class를 선언하여 rename 유발.
    // ES5 lowering 후 __extends(Foo$1, Base), Foo$1.prototype.method = ...
    // 가 올바른 renamed 이름을 참조해야 함.
    const result = await bundleAndRun(
      {
        "index.ts": `
        import { Derived } from "./a";
        import { other } from "./b";
        const d = new Derived();
        console.log(d.value() + "," + other);
      `,
        "a.ts": `
        class Base { value() { return "base"; } }
        export class Derived extends Base {
          value() { return "derived"; }
        }
      `,
        "b.ts": `
        class Derived { x = 1; }
        export const other = new Derived().x;
      `,
      },
      "index.ts",
      ["--target=es5"],
    );
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("derived,1");
  });

  test("ES5 export default class rename — 불필요한 var 재선언 금지", async () => {
    // export default class + ES5 lowering + rename 시
    // var Foo$1 = Foo; 같은 잘못된 재선언이 생기면 함수가 덮어씌워짐.
    const result = await bundleAndRun(
      {
        "index.ts": `
        import MyClass from "./a";
        import { other } from "./b";
        const m = new MyClass();
        console.log(m.name() + "," + other);
      `,
        "a.ts": `
        export default class MyClass {
          name() { return "a"; }
        }
      `,
        "b.ts": `
        class MyClass { x = 1; }
        export const other = new MyClass().x;
      `,
      },
      "index.ts",
      ["--target=es5"],
    );
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("a,1");
  });

  test("ES5 optional chaining rename — X?.prop 양쪽 참조 모두 rename", async () => {
    // X?.now → X == null ? void 0 : X.now 에서
    // 두 X 참조 모두 renamed 이름을 사용해야 함.
    const result = await bundleAndRun(
      {
        "index.ts": `
        import Perf from "./perf";
        import { other } from "./conflict";
        const val = Perf?.now ?? (() => 0);
        console.log(val() + "," + other);
      `,
        "perf.ts": `
        const Perf = { now: () => 42 };
        export default Perf;
      `,
        "conflict.ts": `
        const Perf = "conflict";
        export const other = Perf;
      `,
      },
      "index.ts",
      ["--target=es5"],
    );
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("42,conflict");
  });

  test("ES5 __esm import destructuring rename — 키는 원본 이름 사용", async () => {
    // __esm 모듈에서 import destructuring 시 exports 객체의 키는 원본 이름,
    // 로컬 변수는 renamed 이름이어야 함.
    // ({Base:Base$1}=...) ← 올바름, ({Base$1}=...) ← 잘못됨 (프로퍼티 없음)
    const result = await bundleAndRun(
      {
        "index.ts": `
        import { getChild } from "./consumer";
        console.log(getChild());
      `,
        "consumer.ts": `
        const m = require("./child");
        export function getChild() { return m.Child.value(); }
      `,
        "child.ts": `
        import { Base } from "./base";
        export class Child extends Base {
          static value() { return "child"; }
        }
      `,
        "base.ts": `
        export class Base {}
      `,
        "conflict.ts": `
        export class Base { x = 1; }
      `,
      },
      "index.ts",
      ["--target=es5", "--format=cjs"],
    );
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("child");
  });
});

describe("_default 합성 변수 충돌 방지", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("여러 export default 모듈이 각각 고유한 _default 변수를 갖는다", async () => {
    // 여러 모듈이 export default를 사용할 때,
    // 각 모듈의 합성 변수가 _default, _default$1, _default$2로 분리되어야 한다.
    const result = await bundleAndRun({
      "index.ts": `
        import a from "./a";
        import b from "./b";
        import c from "./c";
        console.log(a + "," + b + "," + c);
      `,
      "a.ts": `export default "alpha";`,
      "b.ts": `export default "beta";`,
      "c.ts": `export default "gamma";`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("alpha,beta,gamma");
  });

  test("default export 표현식과 named default가 혼합되어도 충돌하지 않는다", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        import a from "./a";
        import greet from "./b";
        console.log(a + "," + greet());
      `,
      "a.ts": `export default "anon";`,
      "b.ts": `export default function greet() { return "named"; }`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("anon,named");
  });

  test("CJS→ESM 혼합 시 __esm 래퍼의 _default가 충돌하지 않는다", async () => {
    // CJS 중간 모듈이 ESM 모듈을 require하면 __esm 래퍼가 생성되고,
    // 각 default export가 고유한 변수를 가져야 한다.
    const result = await bundleAndRun({
      "index.ts": `
        import { getA, getB } from "./consumer";
        console.log(getA() + "," + getB());
      `,
      "consumer.ts": `
        const a = require("./a");
        const b = require("./b");
        export function getA() { return a.default; }
        export function getB() { return b.default; }
      `,
      "a.ts": `export default "alpha";`,
      "b.ts": `export default "beta";`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("alpha,beta");
  });

  test("5개 이상의 default export 모듈이 모두 고유 값을 유지한다", async () => {
    const imports = Array.from({ length: 5 }, (_, i) => `import m${i} from "./m${i}";`).join("\n");
    const log = Array.from({ length: 5 }, (_, i) => `m${i}`).join("+','+");
    const files: Record<string, string> = {
      "index.ts": `${imports}\nconsole.log(${log});`,
    };
    for (let i = 0; i < 5; i++) {
      files[`m${i}.ts`] = `export default "v${i}";`;
    }
    const result = await bundleAndRun(files);
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("v0,v1,v2,v3,v4");
  });

  test("CJS 엔트리 모듈이 IIFE 번들에서 자동 호출된다 (#707)", async () => {
    const result = await bundleAndRun({
      "index.ts": `const a = require("./a"); console.log(a.default);`,
      "a.ts": `export default "hello";`,
    });
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("hello");
  });

  test("import + export default 패턴에서 hoisted var가 중복 선언되지 않는다 (#706)", async () => {
    const fixture = await createFixture({
      "index.ts": `const p = require("./proxy"); console.log(p.default);`,
      "proxy.ts": `import b from "./b"; export default b;`,
      "b.ts": `export default "proxied";`,
    });
    cleanup = fixture.cleanup;

    const bundle = await runZts(["--bundle", join(fixture.dir, "index.ts")]);
    expect(bundle.exitCode).toBe(0);

    // var 선언 행에서 같은 이름이 두 번 나오지 않아야 한다
    const varLines = bundle.stdout.split("\n").filter((l) => l.startsWith("var "));
    for (const line of varLines) {
      const names = line
        .replace(/^var /, "")
        .replace(/;$/, "")
        .split(",")
        .map((n) => n.trim());
      const unique = new Set(names);
      expect(unique.size).toBe(names.length);
    }
  });

  test("export { default as X } from re-export가 __esm 래퍼에서 할당된다 (#705)", async () => {
    const fixture = await createFixture({
      "index.ts": `const b = require("./barrel"); console.log(b.Foo);`,
      "barrel.ts": `export { default as Foo } from "./foo";`,
      "foo.ts": `export default "fooValue";`,
    });
    cleanup = fixture.cleanup;

    const bundle = await runZts(["--bundle", join(fixture.dir, "index.ts")]);
    expect(bundle.exitCode).toBe(0);
    // __esm body에 할당문이 있어야 한다
    expect(bundle.stdout).toContain("= _default");
  });

  test("export { default } from re-export가 __esm 래퍼에서 할당된다 (#705)", async () => {
    const fixture = await createFixture({
      "index.ts": `const b = require("./barrel"); console.log(b.default);`,
      "barrel.ts": `export { default } from "./foo";`,
      "foo.ts": `export default "fooValue";`,
    });
    cleanup = fixture.cleanup;

    const bundle = await runZts(["--bundle", join(fixture.dir, "index.ts")]);
    expect(bundle.exitCode).toBe(0);
    expect(bundle.stdout).toContain("= _default");
  });

  test("import Default, { named } from 동시 사용 시 default와 named 모두 정상 바인딩", async () => {
    const result = await bundleAndRun({
      "index.ts": `import Cls, { helper } from "./lib"; console.log(new Cls().name + ":" + helper());`,
      "lib.ts": `export default class Foo { get name() { return "foo"; } }\nexport function helper() { return "ok"; }`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("foo:ok");
  });

  test("CJS require + default/named 혼합 import: __esm body에서 default가 누락되지 않는다", async () => {
    // __esm 래핑 모듈이 다른 __esm 모듈에서 default + named import 시
    // destructuring에 "default" 프로퍼티가 포함되어야 한다.
    const result = await bundleAndRun({
      "index.ts": `const m = require("./entry"); console.log(m.result);`,
      "entry.ts": `import Base, { util } from "./base";\nexport const result = new Base().val + ":" + util();`,
      "base.ts": `export default class Base { get val() { return "base"; } }\nexport function util() { return "u"; }`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("base:u");
  });

  test("ES5 class super(): 동일 이름 클래스가 여러 모듈에 존재할 때 _super로 스코프 격리", async () => {
    // 번들에서 동일 이름의 클래스(EventEmitter)가 두 모듈에 존재할 때
    // super() 호출이 IIFE 매개변수 _super를 사용하여 올바른 부모 클래스를 참조해야 한다.
    const result = await bundleAndRun(
      {
        "index.ts": `import { Child } from "./child"; const c = new Child(); console.log(c.value());`,
        "child.ts": `import { Base } from "./base-a";
export class Child extends Base {
  value() { return "child:" + super.value(); }
}`,
        "base-a.ts": `export class Base {
  value() { return "a"; }
}`,
        "base-b.ts": `export class Base {
  value() { return "b"; }
}`,
      },
      "index.ts",
      ["--target=es5"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("child:a");
  });

  test("ES5 class super(): 상속 체인에서 __classCallCheck가 정상 동작", async () => {
    // class A → class B extends A → class C extends B
    // 각 super() 호출이 _super를 통해 올바르게 연결되어야 한다.
    const result = await bundleAndRun(
      {
        "index.ts": `import { C } from "./c"; const obj = new C(); console.log(obj.name());`,
        "a.ts": `export class Base { name() { return "base"; } }`,
        "b.ts": `import { Base } from "./a";
export class Mid extends Base {
  name() { return "mid>" + super.name(); }
}`,
        "c.ts": `import { Mid } from "./b";
export class C extends Mid {
  name() { return "c>" + super.name(); }
}`,
      },
      "index.ts",
      ["--target=es5"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("c>mid>base");
  });

  test("ES5 __callSuper: extends Error에서 Reflect.construct로 올바른 인스턴스 생성", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `class AppError extends Error {
  constructor(msg: string) {
    super(msg);
    this.name = "AppError";
  }
}
const e = new AppError("test");
console.log(e instanceof Error && e.message === "test" && e.name === "AppError");`,
      },
      "index.ts",
      ["--target=es5"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("true");
  });

  test("ES5 __callSuper: super() 인자 없을 때 빈 배열 전달", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `class Base { args: any[]; constructor(...a: any[]) { this.args = a; } }
class Child extends Base { constructor() { super(); } }
console.log(new Child().args.length);`,
      },
      "index.ts",
      ["--target=es5"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("0");
  });

  test("ES5 __callSuper: super() 후 this → _this 별칭이 중첩 함수에 누출되지 않음", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `class Base { x = 0; }
class Child extends Base {
  fn: () => string;
  constructor() {
    super();
    this.fn = function() { return typeof this; };
  }
}
const c = new Child();
console.log(c.fn.call(undefined));`,
      },
      "index.ts",
      ["--target=es5"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("undefined");
  });

  test("ES5 __callSuper: conditional branch 안의 super()도 정상 동작", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `class Base { v: number; constructor(v: number) { this.v = v; } }
class Child extends Base {
  constructor(x: boolean) {
    if (x) { super(1); } else { super(2); }
    this.v *= 10;
  }
}
console.log(new Child(true).v + ":" + new Child(false).v);`,
      },
      "index.ts",
      ["--target=es5"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("10:20");
  });

  test("ES5 destructuring 파라미터: function({ ref, ...props }) 올바른 변환", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `function test({ ref, ...props }: any) { return ref + ":" + props.x; }
console.log(test({ ref: "hello", x: 42 }));`,
      },
      "index.ts",
      ["--target=es5"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("hello:42");
  });

  test("ES5 destructuring 파라미터 + 기본값: function({ a = 1 }) 변환", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `function test({ a = 10, b }: any) { return a + b; }
console.log(test({ b: 5 }));`,
      },
      "index.ts",
      ["--target=es5"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("15");
  });

  test("ES5 class getter/setter가 configurable: true로 정의되어 이후 재정의 가능", async () => {
    // abort-controller 패턴: class getter 정의 후 Object.defineProperties로 enumerable 추가.
    // configurable: true가 없으면 TypeError: property is not configurable 발생.
    const result = await bundleAndRun(
      {
        "index.ts": `import { Sig } from "./signal";
Object.defineProperties(Sig.prototype, { aborted: { enumerable: true } });
console.log(new Sig().aborted);`,
        "signal.ts": `export class Sig {
  get aborted(): boolean { return false; }
}`,
      },
      "index.ts",
      ["--target=es5"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("false");
  });

  test("export * from 이 __esm 래퍼에서 소스 모듈의 named export를 전파한다", async () => {
    const result = await bundleAndRun({
      "index.ts": `import { greet, add } from "./proxy"; console.log(greet("world") + ":" + add(1, 2));`,
      "proxy.ts": `export * from "./impl";`,
      "impl.ts": `export function greet(name: string) { return "hello " + name; }\nexport function add(a: number, b: number) { return a + b; }`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("hello world:3");
  });

  test("export * from 체인이 정상 동작한다 (A → B → C)", async () => {
    const result = await bundleAndRun({
      "index.ts": `import { value } from "./a"; console.log(value);`,
      "a.ts": `export * from "./b";`,
      "b.ts": `export * from "./c";`,
      "c.ts": `export const value = 42;`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("42");
  });

  test("export * from 이 직접 export보다 우선순위가 낮다", async () => {
    const result = await bundleAndRun({
      "index.ts": `import { value } from "./proxy"; console.log(value);`,
      "proxy.ts": `export const value = "direct";\nexport * from "./impl";`,
      "impl.ts": `export const value = "star";`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("direct");
  });

  test("export * from 이 default를 제외한다 (ESM 스펙)", async () => {
    // export * from은 "default"를 전파하지 않는다 (ECMAScript 15.2.3.5).
    // named export만 전파되고 default는 undefined.
    const result = await bundleAndRun({
      "index.ts": `import { named } from "./proxy"; console.log(named);`,
      "proxy.ts": `export * from "./impl";`,
      "impl.ts": `export default "should_not_propagate";\nexport const named = 1;`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("1");
  });

  test("export * as ns from 이 namespace 객체로 re-export된다", async () => {
    const result = await bundleAndRun({
      "index.ts": `import { ns } from "./proxy"; console.log(ns.x + ":" + ns.y);`,
      "proxy.ts": `export * as ns from "./impl";`,
      "impl.ts": `export const x = "hello";\nexport const y = "world";`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("hello:world");
  });

  test("CJS가 export * from barrel을 require()로 소비한다", async () => {
    // CJS entry가 ESM barrel을 require()하는 패턴.
    // __toCommonJS를 통해 proxy의 star re-export에 접근.
    const result = await bundleAndRun({
      "index.ts": `const p = require("./proxy"); console.log(p.foo + ":" + p.bar);`,
      "proxy.ts": `export * from "./impl";`,
      "impl.ts": `export const foo = "a";\nexport const bar = "b";`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("a:b");
  });
});

describe("entry 모듈 감지", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("CJS entry가 scope-hoisted 의존성보다 뒤에 정렬되어도 정상 실행된다", async () => {
    // CJS entry(require 사용) + scope-hoisted ESM 모듈 조합.
    // bundleOrderLessThan이 wrapped를 먼저 배치하므로 scope-hoisted가 마지막이 됨.
    // exec_index 최대값 기반 entry 감지가 실패하면 require_index()가 호출 안 됨.
    const result = await bundleAndRun({
      "index.ts": `const lib = require("./lib"); console.log(lib.value);`,
      "lib.ts": `export const value = "from-lib";`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("from-lib");
  });

  test("CJS entry + 다수의 scope-hoisted 모듈 체인에서 entry가 정확히 감지된다", async () => {
    const result = await bundleAndRun({
      "index.ts": `const a = require("./a"); console.log(a.val);`,
      "a.ts": `export { val } from "./b";`,
      "b.ts": `export { val } from "./c";`,
      "c.ts": `export const val = "deep";`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("deep");
  });

  test("ESM entry의 export가 IIFE에서 syntax error를 일으키지 않는다", async () => {
    // ESM entry의 scope-hoisted 의존성 모듈이 entry로 오판되면
    // IIFE 안에 export { } 구문이 남아 syntax error 발생.
    const result = await bundleAndRun({
      "index.ts": `import { x } from "./dep"; console.log(x);`,
      "dep.ts": `export const x = "ok";`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("ok");
  });

  test("ESM entry + ESM 래핑 모듈 + scope-hoisted 모듈 혼합에서 정상 동작", async () => {
    // 세 종류의 wrap_kind가 혼합된 경우:
    // index.ts (entry, scope-hoisted) → proxy.ts (ESM wrapped) → impl.ts (scope-hoisted)
    // CJS로 require하는 패턴이 없어도, barrel re-export 시 ESM wrapping이 발생.
    const result = await bundleAndRun({
      "index.ts": `import { foo } from "./proxy"; console.log(foo);`,
      "proxy.ts": `export * from "./impl";`,
      "impl.ts": `export const foo = "mixed";`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("mixed");
  });
});

describe("export type/interface + module.exports → CJS 판별 (#713)", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("TS: export type alias + module.exports → __commonJS 래핑", async () => {
    const result = await bundleAndRun(
      {
        "entry.ts": `const lib = require("./lib"); console.log(lib.value);`,
        "lib.ts": `export type Foo = string;\nmodule.exports = { value: 42 };`,
      },
      "entry.ts",
    );
    cleanup = result.cleanup;
    expect(result.runOutput).toBe("42");
  });

  test("TS: export interface + module.exports → __commonJS 래핑", async () => {
    const result = await bundleAndRun(
      {
        "entry.ts": `const lib = require("./lib"); console.log(lib.value);`,
        "lib.ts": `export interface Bar { x: number; }\nmodule.exports = { value: 99 };`,
      },
      "entry.ts",
    );
    cleanup = result.cleanup;
    expect(result.runOutput).toBe("99");
  });

  test("Flow: export type alias + module.exports → __commonJS 래핑", async () => {
    const result = await bundleAndRun(
      {
        "entry.js": `const lib = require("./lib"); console.log(lib.value);`,
        "lib.js": `// @flow\nexport type Foo = string;\nmodule.exports = { value: 7 };`,
      },
      "entry.js",
      ["--flow"],
    );
    cleanup = result.cleanup;
    expect(result.runOutput).toBe("7");
  });

  test("Flow: import typeof + export type + module.exports → __commonJS 래핑 (RN 패턴)", async () => {
    const result = await bundleAndRun(
      {
        "entry.js": `const lib = require("./iface"); console.log(lib.value);`,
        "iface.js": `// @flow strict-local\nimport typeof Dep from "./dep";\nexport type X = string;\nexport type {Dep};\nmodule.exports = { value: 55 };`,
        "dep.js": `module.exports = {};`,
      },
      "entry.js",
      ["--flow"],
    );
    cleanup = result.cleanup;
    expect(result.runOutput).toBe("55");
  });

  test("Flow: export opaque type + module.exports → __commonJS 래핑", async () => {
    const result = await bundleAndRun(
      {
        "entry.js": `const lib = require("./lib"); console.log(lib.value);`,
        "lib.js": `// @flow\nexport opaque type ID = string;\nmodule.exports = { value: 33 };`,
      },
      "entry.js",
      ["--flow"],
    );
    cleanup = result.cleanup;
    expect(result.runOutput).toBe("33");
  });

  test("TS: export type + export const 혼합 → value export 유지", async () => {
    const result = await bundleAndRun(
      {
        "entry.ts": `import { value } from "./lib"; console.log(value);`,
        "lib.ts": `export type Foo = string;\nexport const value = 123;`,
      },
      "entry.ts",
    );
    cleanup = result.cleanup;
    expect(result.runOutput).toBe("123");
  });
});

describe("에셋 로더 + RN 프리셋", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("loader 미설정 시 .png 빌드 에러", async () => {
    const fixture = await createFixture({
      "entry.ts": `const icon = require('./icon.png');\nconsole.log(icon);`,
    });
    cleanup = fixture.cleanup;
    // 바이너리 파일은 createFixture(문자열 전용)로 못 만들므로 직접 작성
    writeFileSync(join(fixture.dir, "icon.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47]));

    const result = await runZtsInDir(fixture.dir, ["--bundle", join(fixture.dir, "entry.ts")]);
    expect(result.stderr).toContain("No loader is configured");
  });

  test("--loader:.png=file 시 .png 번들 성공", async () => {
    const fixture = await createFixture({
      "entry.ts": `const icon = require('./icon.png');\nconsole.log(icon);`,
    });
    cleanup = fixture.cleanup;
    writeFileSync(join(fixture.dir, "icon.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47]));

    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      join(fixture.dir, "entry.ts"),
      "--loader:.png=file",
    ]);
    expect(result.stderr).not.toContain("No loader");
    expect(result.stdout).toContain("require_icon");
  });

  test("--platform=react-native 시 .png 자동 처리", async () => {
    const fixture = await createFixture({
      "entry.ts": `const icon = require('./icon.png');\nconsole.log(icon);`,
    });
    cleanup = fixture.cleanup;
    writeFileSync(join(fixture.dir, "icon.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47]));

    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      join(fixture.dir, "entry.ts"),
      "--platform=react-native",
    ]);
    expect(result.stderr).not.toContain("No loader");
    expect(result.stdout).toContain("require_icon");
  });

  test("--platform=react-native 사용자 로더 우선", async () => {
    const fixture = await createFixture({
      "entry.ts": `const icon = require('./icon.png');\nconsole.log(icon);`,
    });
    cleanup = fixture.cleanup;
    writeFileSync(join(fixture.dir, "icon.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47]));

    // 사용자가 --loader:.png=dataurl 지정 → file 대신 dataurl 사용
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      join(fixture.dir, "entry.ts"),
      "--platform=react-native",
      "--loader:.png=dataurl",
    ]);
    expect(result.stderr).not.toContain("No loader");
    expect(result.stdout).toContain("data:image/png;base64,");
  });

  test("--platform=react-native 비이미지 에셋 (.mp3) 자동 처리", async () => {
    const fixture = await createFixture({
      "entry.ts": `const audio = require('./sound.mp3');\nconsole.log(audio);`,
    });
    cleanup = fixture.cleanup;
    writeFileSync(join(fixture.dir, "sound.mp3"), "fake-mp3-data");

    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      join(fixture.dir, "entry.ts"),
      "--platform=react-native",
    ]);
    expect(result.stderr).not.toContain("No loader");
    expect(result.stdout).toContain("require_sound");
  });

  test("ESM import 에셋도 no-loader 에러", async () => {
    const fixture = await createFixture({
      "entry.ts": `import icon from './icon.png';\nconsole.log(icon);`,
    });
    cleanup = fixture.cleanup;
    writeFileSync(join(fixture.dir, "icon.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47]));

    const result = await runZtsInDir(fixture.dir, ["--bundle", join(fixture.dir, "entry.ts")]);
    expect(result.stderr).toContain("No loader is configured");
  });

  test("loader=empty → undefined export", async () => {
    const fixture = await createFixture({
      "entry.ts": `const x = require('./data.bin');\nconsole.log(typeof x);`,
    });
    cleanup = fixture.cleanup;
    writeFileSync(join(fixture.dir, "data.bin"), "binary-data");

    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      join(fixture.dir, "entry.ts"),
      "--loader:.bin=empty",
    ]);
    expect(result.stderr).not.toContain("No loader");
    expect(result.stdout).toContain("undefined");
  });
});

describe("JSON named exports", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("import { name } from './app.json' 동작", async () => {
    const result = await bundleAndRun({
      "index.ts": `import { name, displayName } from './app.json';\nconsole.log(name + ":" + displayName);`,
      "app.json": `{"name":"ExampleApp","displayName":"Example"}`,
    });
    cleanup = result.cleanup;
    expect(result.runOutput).toBe("ExampleApp:Example");
  });

  test("default + named export 공존", async () => {
    const result = await bundleAndRun({
      "index.ts": `import config, { name } from './app.json';\nconsole.log(name + ":" + typeof config);`,
      "app.json": `{"name":"Test","version":1}`,
    });
    cleanup = result.cleanup;
    expect(result.runOutput).toBe("Test:object");
  });

  test("배열 JSON은 named export 없음", async () => {
    const result = await bundleAndRun({
      "index.ts": `import data from './data.json';\nconsole.log(data.length);`,
      "data.json": `[1, 2, 3]`,
    });
    cleanup = result.cleanup;
    expect(result.runOutput).toBe("3");
  });
});

describe("JSX classic 모드 번들러 rename", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("JSX 컴포넌트 이름이 번들러 rename을 반영한다", async () => {
    // 두 모듈에서 동일한 이름(Text)을 사용하여 번들러가 rename하게 유도
    const fixture = await createFixture({
      "index.tsx": `
        import { Text } from "./ui";
        import { Text as Label } from "./label";
        export function App() {
          return <Text value="hello" />;
        }
        export function Sub() {
          return <Label value="world" />;
        }
      `,
      "ui.tsx": `
        export function Text({ value }: { value: string }) {
          return value;
        }
      `,
      "label.tsx": `
        export function Text({ value }: { value: string }) {
          return "[" + value + "]";
        }
      `,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts([
      "--bundle",
      join(fixture.dir, "index.tsx"),
      "-o",
      outFile,
      "--jsx=classic",
    ]);
    expect(bundle.exitCode).toBe(0);

    const output = readFileSync(outFile, "utf-8");

    // createElement 호출에서 두 Text 함수가 다른 이름으로 참조되어야 함
    // $는 \w에 포함되므로 [\w$]+로 매치 (Text$1 등)
    const calls = [...output.matchAll(/React\.createElement\(([\w$]+)/g)].map((m) => m[1]);
    expect(calls.length).toBe(2);
    // 두 컴포넌트 이름이 달라야 함 (하나는 Text, 다른 하나는 Text$1)
    expect(calls[0]).not.toBe(calls[1]);

    // 각 createElement의 컴포넌트가 실제 함수 선언과 일치하는지 확인
    for (const name of calls) {
      expect(output).toContain(`function ${name}(`);
    }
  });

  test("JSX member expression (<Foo.Bar>) rename", async () => {
    const fixture = await createFixture({
      "index.tsx": `
        import * as UI from "./ui";
        export function App() {
          return <UI.Button label="click" />;
        }
      `,
      "ui.tsx": `
        export function Button({ label }: { label: string }) {
          return label;
        }
      `,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts([
      "--bundle",
      join(fixture.dir, "index.tsx"),
      "-o",
      outFile,
      "--jsx=classic",
    ]);
    expect(bundle.exitCode).toBe(0);

    const output = readFileSync(outFile, "utf-8");

    // member expression이 올바르게 출력되어야 함 (namespace.Button 형태)
    const memberMatch = output.match(/React\.createElement\((\w+)\.Button/);
    expect(memberMatch).not.toBeNull();
  });
});
