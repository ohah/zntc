import { describe, test, expect, afterEach } from "bun:test";
import { bundleAndRun, runZts, createFixture, ZTS_BIN } from "./helpers";
import { existsSync } from "node:fs";
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
});
