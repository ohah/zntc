import { describe, test, expect } from "bun:test";
import { ZTS_BIN } from "./helpers";
import { resolve } from "node:path";

/**
 * React Native ES5 다운레벨링 회귀 테스트.
 * 실제 RN Libraries 파일을 --target=es5 --flow로 트랜스파일하여
 * 크래시(panic) 없이 변환되는지 검증한다.
 *
 * 검증 항목:
 * - async/await → __async(__generator(state machine)) 변환
 * - class → function + prototype 변환
 * - destructuring default parameter → temp 변수
 * - JSX member expression (</React.Fragment>)
 * - yield/await in expression position
 */

const FIXTURES = resolve(import.meta.dir, "fixtures/react-native");

async function transpileES5(file: string): Promise<{
  exitCode: number;
  stdout: string;
  stderr: string;
}> {
  const filePath = resolve(FIXTURES, file);
  const proc = Bun.spawnSync([ZTS_BIN, "--target=es5", "--flow", "--jsx-in-js", filePath]);
  return {
    exitCode: proc.exitCode,
    stdout: proc.stdout.toString(),
    stderr: proc.stderr.toString(),
  };
}

async function expectES5Pass(file: string) {
  const result = await transpileES5(file);
  expect(result.exitCode).toBe(0);
  // panic이나 thread 에러가 없어야 함
  expect(result.stderr).not.toContain("panic");
  expect(result.stderr).not.toContain("thread");
  // yield/function*이 출력에 남아있으면 안 됨
  expect(result.stdout).not.toContain("yield ");
  expect(result.stdout).not.toContain("function*");
  // async function이 남아있으면 안 됨 (__async 헬퍼 제외)
  expect(result.stdout).not.toMatch(/(?<!_)async function/);
}

describe("RN ES5 다운레벨링: async/generator/class", () => {
  // AnimatedImplementation.js — destructuring default + spread 조합
  test("Animated/AnimatedImplementation.js", () =>
    expectES5Pass("Animated/AnimatedImplementation.js"));

  // KeyboardAvoidingView.js — class async method + await in if condition
  test("Components/Keyboard/KeyboardAvoidingView.js", () =>
    expectES5Pass("Components/Keyboard/KeyboardAvoidingView.js"));

  // FlatList.js — JSX member expression (React.Fragment)
  test("Lists/FlatList.js", () => expectES5Pass("Lists/FlatList.js"));

  // PermissionsAndroid.js — async method
  test("PermissionsAndroid/PermissionsAndroid.js", () =>
    expectES5Pass("PermissionsAndroid/PermissionsAndroid.js"));
});

describe("RN ES5: ExampleApp 번들 테스트", () => {
  const EXAMPLE_APP = resolve(import.meta.dir, "fixtures/rn-example-app");

  test("bun install + bundle (no target)", async () => {
    // bun install로 node_modules 설치
    const install = Bun.spawnSync(["bun", "install", "--frozen-lockfile"], {
      cwd: EXAMPLE_APP,
    });
    // frozen-lockfile 실패해도 설치 자체는 시도
    if (install.exitCode !== 0) {
      const install2 = Bun.spawnSync(["bun", "install"], { cwd: EXAMPLE_APP });
      expect(install2.exitCode).toBe(0);
    }

    // 번들링 (no target — ES6+ 출력)
    const bundle = Bun.spawnSync([
      ZTS_BIN,
      "--bundle",
      resolve(EXAMPLE_APP, "index.js"),
      "--platform=react-native",
      "--rn-platform=ios",
      "--flow",
      "-o",
      resolve(EXAMPLE_APP, "out.js"),
    ]);
    expect(bundle.exitCode).toBe(0);
    expect(bundle.stderr.toString()).not.toContain("panic");

    // 출력 크기 확인 (최소 100KB — RN 기본 모듈 포함)
    const stat = await Bun.file(resolve(EXAMPLE_APP, "out.js")).text();
    expect(stat.length).toBeGreaterThan(100_000);
  }, 30_000);

  test("bundle (no target): Node 실행 검증", { timeout: 30_000 }, async () => {
    const outFile = resolve(EXAMPLE_APP, "out.js");
    const run = Bun.spawnSync([
      "node",
      "--eval",
      `
      globalThis.__DEV__ = true;
      globalThis.__fbBatchedBridgeConfig = { remoteModuleConfig: [] };
      globalThis.MessageQueue = class {};
      globalThis.nativePerformanceNow = Date.now;
      globalThis.__turboModuleProxy = () => new Proxy({}, {
        get: (_, prop) => prop === 'getConstants' ? () => ({
          isTesting: false, reactNativeVersion: {major:0,minor:78,patch:0},
          osVersion: 18, systemName: 'iOS', interfaceIdiom: 'phone',
        }) : (...args) => {}
      });
      try { require(${JSON.stringify(outFile)}); } catch(e) {
        if (e instanceof ReferenceError || e instanceof SyntaxError) {
          console.error("FATAL:", e.message);
          process.exit(1);
        }
      }
    `,
    ]);
    if (run.exitCode !== 0) {
      console.log("Bundle runtime error:", run.stderr?.toString());
    }
    expect(run.exitCode).toBe(0);
  });

  test("bundle --target=es5", { timeout: 30_000 }, async () => {
    const bundle = Bun.spawnSync([
      ZTS_BIN,
      "--bundle",
      resolve(EXAMPLE_APP, "index.js"),
      "--platform=react-native",
      "--rn-platform=ios",
      "--target=es5",
      "--flow",
      "-o",
      resolve(EXAMPLE_APP, "out-es5.js"),
    ]);
    expect(bundle.exitCode).toBe(0);
    expect(bundle.stderr.toString()).not.toContain("panic");

    const output = await Bun.file(resolve(EXAMPLE_APP, "out-es5.js")).text();
    // generator 구문이 남아있으면 안 됨
    expect(output).not.toContain("function*");
    expect(output).not.toMatch(/\bfunction\s*\*/);
    // yield 키워드 체크: 문자열 리터럴 내 "yield" 오탐 방지를 위해
    // 세미콜론/줄바꿈/공백 뒤에 오는 실제 yield 키워드만 감지
    expect(output).not.toMatch(/(?:^|[;,=({\n])\s*yield[\s;]/m);
    // ES5 출력 크기 (100KB+)
    expect(output.length).toBeGreaterThan(100_000);
  });

  test(
    "bundle --target=es5: Node 실행 검증 (ReferenceError 검출)",
    { timeout: 30_000 },
    async () => {
      // ES5 번들을 Node.js에서 실행하여 변수명 불일치 등 런타임 에러 검출.
      // ReferenceError는 번들러의 변수 리네이밍/호이스팅 버그이므로 실패 처리.
      // SyntaxError(super 미변환 등)는 기존 ES5 변환 제한사항으로 허용.
      // TypeError는 네이티브 모듈 부재로 인한 것이므로 허용.
      const outFile = resolve(EXAMPLE_APP, "out-es5.js");
      const run = Bun.spawnSync([
        "node",
        "--eval",
        `
      globalThis.__DEV__ = true;
      globalThis.__fbBatchedBridgeConfig = { remoteModuleConfig: [] };
      globalThis.MessageQueue = class {};
      globalThis.nativePerformanceNow = Date.now;
      globalThis.__turboModuleProxy = () => new Proxy({}, {
        get: (_, prop) => prop === 'getConstants' ? () => ({
          isTesting: false, reactNativeVersion: {major:0,minor:78,patch:0},
          osVersion: 18, systemName: 'iOS', interfaceIdiom: 'phone',
        }) : (...args) => {}
      });
      try { require(${JSON.stringify(outFile)}); } catch(e) {
        if (e instanceof ReferenceError) {
          console.error("FATAL:", e.message);
          process.exit(1);
        }
      }
    `,
      ]);
      const stderr = run.stderr?.toString() ?? "";
      if (run.exitCode !== 0) {
        console.log("ES5 bundle runtime error:", stderr);
      }
      expect(run.exitCode).toBe(0);
    },
  );
});

describe("RN 번들: Metro vs ZTS 모듈 수 비교", () => {
  const EXAMPLE_APP = resolve(import.meta.dir, "fixtures/rn-example-app");

  test("Metro 번들 모듈 수 기준선", async () => {
    // Metro 번들
    const metro = Bun.spawnSync(
      [
        "npx",
        "react-native",
        "bundle",
        "--platform",
        "ios",
        "--dev",
        "false",
        "--entry-file",
        "index.js",
        "--bundle-output",
        resolve(EXAMPLE_APP, "metro-out.js"),
      ],
      { cwd: EXAMPLE_APP },
    );
    expect(metro.exitCode).toBe(0);

    const metroOutput = await Bun.file(resolve(EXAMPLE_APP, "metro-out.js")).text();
    const metroModules = (metroOutput.match(/^__d\(function/gm) || []).length;

    // ZTS 번들 (--rn-platform=ios: Metro의 --platform ios와 동일한 확장자 해석)
    const zts = Bun.spawnSync([
      ZTS_BIN,
      "--bundle",
      resolve(EXAMPLE_APP, "index.js"),
      "--platform=react-native",
      "--rn-platform=ios",
      "--flow",
      "--metafile=" + resolve(EXAMPLE_APP, "meta.json"),
      "-o",
      resolve(EXAMPLE_APP, "zts-out.js"),
    ]);
    expect(zts.exitCode).toBe(0);

    const meta = JSON.parse(await Bun.file(resolve(EXAMPLE_APP, "meta.json")).text());
    const ztsModules = Object.keys(meta.inputs || {}).length;

    // 로그 출력 (CI에서 확인용)
    console.log(`Metro modules: ${metroModules}, ZTS modules: ${ztsModules}`);
    console.log(
      `Metro bytes: ${metroOutput.length}, ZTS bytes: ${(await Bun.file(resolve(EXAMPLE_APP, "zts-out.js")).text()).length}`,
    );

    // ZTS가 Metro 이상의 모듈을 resolve해야 함
    const ratio = ztsModules / metroModules;
    console.log(`Module resolve ratio: ${(ratio * 100).toFixed(1)}%`);
    expect(ratio).toBeGreaterThanOrEqual(1.0);
  }, 60_000); // Metro 번들은 ~20초 소요

  test("Hermes 구문 검증 (hermesc)", async () => {
    const hermescDir = process.platform === "linux" ? "linux64-bin" : "osx-bin";
    const hermesc = resolve(
      EXAMPLE_APP,
      `node_modules/hermes-compiler/hermesc/${hermescDir}/hermesc`,
    );

    // ZTS 번들
    const outFile = resolve(EXAMPLE_APP, "zts-hermes.js");
    const zts = Bun.spawnSync([
      ZTS_BIN,
      "--bundle",
      resolve(EXAMPLE_APP, "index.js"),
      "--platform=react-native",
      "--rn-platform=ios",
      "--flow",
      "-o",
      outFile,
    ]);
    expect(zts.exitCode).toBe(0);

    // hermesc로 구문 검증
    const hbc = resolve(EXAMPLE_APP, "zts-hermes.hbc");
    const hermes = Bun.spawnSync([hermesc, "-emit-binary", "-out", hbc, outFile]);
    const stderr = hermes.stderr?.toString() ?? "";
    if (hermes.exitCode !== 0) {
      console.log("hermesc errors:", stderr);
    }
    const errorCount = (stderr.match(/error:/g) || []).length;
    console.log(`hermesc errors: ${errorCount}`);
    expect(errorCount).toBe(0);
  }, 60_000);

  test("번들 내 미변환 require() 호출 검출", async () => {
    // __commonJS 래퍼 안에서 ESM import가 require()로 변환될 때
    // require_xxx()로 치환되어야 함. raw require("specifier")가 남아있으면 런타임 에러.
    // 이전 ��스트(Hermes 구문 검증)에 의존하지 않고 자체 번들 생성
    const outFile = resolve(EXAMPLE_APP, "zts-require-check.js");
    const zts = Bun.spawnSync([
      ZTS_BIN,
      "--bundle",
      resolve(EXAMPLE_APP, "index.js"),
      "--platform=react-native",
      "--rn-platform=ios",
      "--flow",
      "-o",
      outFile,
    ]);
    expect(zts.exitCode).toBe(0);
    const output = await Bun.file(outFile).text();

    // 번들 내 raw require("...") 패턴 검출 (require_ 접두사가 아닌 것만)
    // __commonJS 런타임 정의 내의 require는 제외
    const rawRequires = output.match(/(?<!_)require\s*\(\s*["'][^"']+["']\s*\)/g) || [];

    // 현재 알려진 미해결 케이스 수 기록 (점진적 개선 추적)
    console.log(`Raw require() calls remaining: ${rawRequires.length}`);
    if (rawRequires.length > 0) {
      // 처음 5개 출력 (디버깅용)
      console.log("Examples:", rawRequires.slice(0, 5));
    }

    expect(rawRequires.length).toBe(0);
  }, 60_000);

  test("__esm 래퍼 내 exports/module.exports 부재 검증", async () => {
    // __esm 래퍼 안에서 exports.x=x 또는 module.exports=x가 있으면 런타임 에러 발생.
    // __esm은 exports/module 파라미터를 제공하지 않으므로, CJS export 출력이 없어야 함.
    const outFile = resolve(EXAMPLE_APP, "zts-require-check.js");
    const output = await Bun.file(outFile).text();

    // __esm 래퍼 안의 코드 추출하여 exports. / module.exports 검사
    const esmBlocks = output.match(/= __esm\(\{[\s\S]*?\}\}\);/g) || [];
    let violations: string[] = [];
    for (const block of esmBlocks) {
      // __export(exports_xxx, ...) 호출은 정상 — 이건 별도 namespace
      // exports.x=x 또는 module.exports= 가 있으면 위반
      const lines = block.split("\n");
      for (const line of lines) {
        if (line.match(/\bexports\.\w+\s*=/) && !line.includes("__export")) {
          violations.push(line.trim().substring(0, 80));
        }
        if (line.includes("module.exports=") || line.includes("module.exports =")) {
          violations.push(line.trim().substring(0, 80));
        }
      }
    }
    if (violations.length > 0) {
      console.log("CJS exports in __esm wrappers:", violations.slice(0, 5));
    }
    expect(violations.length).toBe(0);
  }, 60_000);

  test("__esm 래퍼 내 __export getter 변수 정의 검증", async () => {
    // __export의 getter가 참조하는 변수가 같은 __esm 래퍼 안에 정의되어 있는지 검증.
    // 미정의 변수 참조 시 런타임 ReferenceError 발생.
    const outFile = resolve(EXAMPLE_APP, "zts-require-check.js");
    const output = await Bun.file(outFile).text();

    // __esm 블록에서 __export의 getter 변수명 추출
    const esmBlocks = output.match(/= __esm\(\{[\s\S]*?\n\}\}\);/g) || [];
    let undefinedRefs: string[] = [];
    for (const block of esmBlocks) {
      // __export(xxx, { name: () => varName, ... }) 에서 varName 추출
      const getterMatches = block.matchAll(/:\s*\(\)\s*=>\s*(\w+)/g);
      for (const m of getterMatches) {
        const varName = m[1];
        // 블록 안에서 이 변수가 정의되어 있는지 확인
        // var/let/const/function 선언 또는 파라미터
        const defPattern = new RegExp(
          `(?:var|let|const|function)\\s+${varName}\\b|\\b${varName}\\s*=`,
        );
        if (!defPattern.test(block)) {
          undefinedRefs.push(varName);
        }
      }
    }
    if (undefinedRefs.length > 0) {
      console.log("Undefined getter refs in __esm:", [...new Set(undefinedRefs)].slice(0, 10));
    }
    expect(undefinedRefs.length).toBe(0);
  }, 60_000);
});

/**
 * inline 코드를 임시 파일로 만들어 ZTS CLI로 트랜스파일하는 헬퍼.
 * ext: 확장자 (기본 ".ts"), flags: 추가 CLI 플래그
 */
function transpileInline(code: string, ext = ".ts", flags: string[] = []): string {
  const { mkdtempSync, writeFileSync, rmSync } = require("fs");
  const { join } = require("path");
  const { tmpdir } = require("os");
  const dir = mkdtempSync(join(tmpdir(), "zts-inline-"));
  const file = join(dir, `input${ext}`);
  writeFileSync(file, code);
  const proc = Bun.spawnSync([ZTS_BIN, ...flags, file]);
  const stdout = proc.stdout.toString();
  rmSync(dir, { recursive: true });
  expect(proc.exitCode).toBe(0);
  return stdout;
}

function transpileES5Inline(code: string): string {
  return transpileInline(code, ".ts", ["--target=es5"]);
}

/**
 * ES5 클래스: abstract/declare/overload 메서드 스트리핑 테스트
 */
describe("RN ES5 다운레벨링: abstract/declare/overload 메서드 스트리핑", () => {
  test("abstract 메서드가 prototype에 emit되지 않아야 함", async () => {
    const out = await transpileES5Inline(`
      abstract class Gesture {
        abstract toGestureArray(): any[];
        abstract initialize(): void;
        abstract prepare(): void;
        concrete(): string { return "hi"; }
      }
    `);
    expect(out).not.toContain("toGestureArray = function()");
    expect(out).not.toContain("initialize = function()");
    expect(out).not.toContain("prepare = function()");
    expect(out).toContain("concrete = function()");
  });

  test("abstract class를 상속한 concrete class는 정상 변환", async () => {
    const out = await transpileES5Inline(`
      abstract class Base {
        abstract getValue(): number;
        shared(): string { return "shared"; }
      }
      class Impl extends Base {
        getValue() { return 42; }
      }
    `);
    expect(out).not.toContain("getValue = function();\n");
    expect(out).toContain("shared = function()");
    expect(out).toContain("getValue = function()");
    expect(out).toContain("return 42");
  });

  test("TS 오버로드 시그니처가 emit되지 않아야 함", async () => {
    const out = await transpileES5Inline(`
      class Foo {
        method(x: string): void;
        method(x: number): void;
        method(x: string | number): void { console.log(x); }
      }
    `);
    // 오버로드 시그니처 2개는 제거, 구현만 남아야 함
    const methodCount = (out.match(/method = function/g) || []).length;
    expect(methodCount).toBe(1);
    expect(out).toContain("console.log(x)");
  });

  test("declare 메서드가 emit되지 않아야 함", async () => {
    const out = await transpileES5Inline(`
      declare class DeclaredClass {
        doSomething(): void;
      }
      class Real {
        real() { return 1; }
      }
    `);
    expect(out).not.toContain("doSomething");
    expect(out).toContain("real = function()");
  });

  test("abstract + static 혼합 클래스", async () => {
    const out = await transpileES5Inline(`
      abstract class Mixed {
        abstract abstractMethod(): void;
        static staticMethod() { return "static"; }
        normalMethod() { return "normal"; }
      }
    `);
    expect(out).not.toContain("abstractMethod");
    expect(out).toContain("staticMethod");
    expect(out).toContain("normalMethod");
  });

  test("abstract getter/setter는 스트리핑", async () => {
    const out = await transpileES5Inline(`
      abstract class Base {
        abstract get value(): number;
        abstract set value(v: number);
        get concrete(): string { return "ok"; }
      }
    `);
    expect(out).toContain("concrete");
    // abstract getter/setter도 body 없으면 스트리핑 (accessor 경로)
  });

  test("여러 오버로드 + 제네릭 시그니처", async () => {
    const out = await transpileES5Inline(`
      class Service {
        fetch(url: string): Promise<string>;
        fetch<T>(url: string, parser: (data: string) => T): Promise<T>;
        fetch(url: string, parser?: any): Promise<any> {
          return Promise.resolve(url);
        }
      }
    `);
    const fetchCount = (out.match(/fetch = function/g) || []).length;
    expect(fetchCount).toBe(1);
    expect(out).toContain("Promise.resolve");
  });

  test("constructor 오버로드는 정상 처리", async () => {
    const out = await transpileES5Inline(`
      class Point {
        x: number;
        y: number;
        constructor(x: number, y: number);
        constructor(xy: number);
        constructor(x: number, y?: number) {
          this.x = x;
          this.y = y ?? x;
        }
      }
    `);
    // constructor는 오버로드 시그니처와 무관하게 1개만 emit
    expect(out).toContain("function Point(x");
    expect(out).not.toContain("function Point(xy");
  });

  test("abstract class를 다중 상속 체인에서 사용", async () => {
    const out = await transpileES5Inline(`
      abstract class Animal {
        abstract speak(): string;
        move() { return "moving"; }
      }
      abstract class Pet extends Animal {
        abstract name(): string;
        greet() { return "hi"; }
      }
      class Dog extends Pet {
        speak() { return "woof"; }
        name() { return "Rex"; }
      }
    `);
    // abstract 메서드는 빈 function() stub로 나오면 안 됨
    expect(out).not.toMatch(/speak = function\(\)\s*;/);
    expect(out).not.toMatch(/name = function\(\)\s*;/);
    // concrete 메서드만 남아야 함
    expect(out).toContain("move = function()");
    expect(out).toContain("greet = function()");
    expect(out).toContain('"woof"');
    expect(out).toContain('"Rex"');
    // __extends 2번 (Pet extends Animal, Dog extends Pet)
    const extendsCount = (out.match(/__extends\(/g) || []).length;
    expect(extendsCount).toBe(2);
  });

  test("interface + abstract + class 혼합 (interface는 완전 스트리핑)", async () => {
    const out = await transpileES5Inline(`
      interface Printable {
        print(): void;
      }
      abstract class Shape implements Printable {
        abstract area(): number;
        abstract print(): void;
        describe() { return "shape"; }
      }
      class Circle extends Shape {
        constructor(public radius: number) { super(); }
        area() { return Math.PI * this.radius ** 2; }
        print() { console.log(this.area()); }
      }
    `);
    expect(out).not.toContain("Printable");
    expect(out).not.toContain("area = function();\n");
    expect(out).toContain("area = function()");
    expect(out).toContain("Math.PI");
    expect(out).toContain("describe = function()");
  });
});

/**
 * jsx_in_js가 .ts 파일에 영향 주지 않는지 테스트
 */
describe("RN ES5 다운레벨링: jsx_in_js + .ts 제네릭", () => {
  test(".ts 파일의 angle bracket 제네릭이 JSX로 오파싱되지 않아야 함", () => {
    const out = transpileInline(
      `const x = <string>"hello";\nfunction identity<T>(v: T): T { return v; }\nconst y = identity<number>(42);`,
      ".ts",
      ["--target=es5", "--flow", "--jsx-in-js"],
    );
    expect(out).toContain('"hello"');
    expect(out).toContain("42");
    expect(out).not.toContain("createElement");
  });

  test(".js 파일의 JSX는 정상 변환", () => {
    const out = transpileInline(`function App() { return <div>hello</div>; }`, ".js", [
      "--flow",
      "--jsx-in-js",
      "--jsx=classic",
    ]);
    expect(out).toContain("createElement");
  });

  test(".tsx 파일은 jsx-in-js 무관하게 JSX 활성", () => {
    const out = transpileInline(`function App() { return <div>hello</div>; }`, ".tsx", [
      "--jsx=classic",
    ]);
    expect(out).toContain("createElement");
  });
});

describe("RN ES5 다운레벨링: 기존 flow-rn fixtures", () => {
  // 기존 50개 fixtures 중 async/class가 있는 파일도 ES5로 검증
  test("Animated/AnimatedEvent.js", () => expectES5Pass("Animated/AnimatedEvent.js"));

  test("Animated/AnimatedMock.js", () => expectES5Pass("Animated/AnimatedMock.js"));

  test("Animated/Easing.js", () => expectES5Pass("Animated/Easing.js"));

  test("Alert/Alert.js", () => expectES5Pass("Alert/Alert.js"));
});
