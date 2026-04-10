import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { init, transpile, build, buildSync, close, type ZtsPlugin } from "./index";
import { resolve } from "node:path";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

beforeAll(() => {
  init();
});

afterAll(() => {
  close();
});

describe("@zts/core", () => {
  test("기본 TypeScript 트랜스파일", () => {
    const result = transpile("const x: number = 1;");
    expect(result.code).toContain("const x = 1;");
    expect(result.map).toBeUndefined();
  });

  test("인터페이스 스트리핑", () => {
    const result = transpile("interface Foo { bar: string; }\nconst x = 1;");
    expect(result.code).not.toContain("interface");
    expect(result.code).toContain("const x = 1;");
  });

  test("타입 어노테이션 제거", () => {
    const result = transpile("function add(a: number, b: number): number { return a + b; }");
    expect(result.code).toContain("function add(a,b)");
    expect(result.code).not.toContain(": number");
  });

  test("enum 변환", () => {
    const result = transpile("enum Color { Red, Green, Blue }");
    expect(result.code).toContain("Color");
  });

  test("JSX 트랜스파일 (classic)", () => {
    const result = transpile('<div className="app">hello</div>', {
      filename: "app.tsx",
      jsx: "classic",
    });
    expect(result.code).toContain("React.createElement");
  });

  test("JSX 트랜스파일 (automatic)", () => {
    const result = transpile('<div className="app">hello</div>', {
      filename: "app.tsx",
      jsx: "automatic",
    });
    expect(result.code).toContain("jsx");
  });

  test("소스맵 생성", () => {
    const result = transpile("const x: number = 1;", { sourcemap: true });
    expect(result.code).toContain("const x = 1;");
    expect(result.map).toBeDefined();
    const map = JSON.parse(result.map!);
    expect(map.version).toBe(3);
    expect(map.mappings).toBeDefined();
  });

  test("minify", () => {
    const result = transpile("const   x: number   =   1;", {
      minifyWhitespace: true,
    });
    expect(result.code.length).toBeLessThan("const   x   =   1;".length);
  });

  test("CJS 포맷", () => {
    const result = transpile('export const x = 1; export default "hello";', {
      format: "cjs",
    });
    expect(result.code).toContain("exports");
  });

  test("빈 소스 에러", () => {
    expect(() => transpile("")).toThrow();
  });

  test("파싱 에러", () => {
    expect(() => transpile("const = ;")).toThrow();
  });

  test("Flow 스트리핑", () => {
    const result = transpile("// @flow\nfunction foo(x: string): number { return 1; }", {
      flow: true,
      filename: "test.js",
    });
    expect(result.code).not.toContain(": string");
    expect(result.code).not.toContain(": number");
  });

  test("drop console", () => {
    const result = transpile('console.log("hello"); const x = 1;', {
      dropConsole: true,
    });
    expect(result.code).not.toContain("console.log");
    expect(result.code).toContain("const x = 1;");
  });

  test("filename으로 확장자 감지 (.tsx)", () => {
    const result = transpile("const el = <div />;", { filename: "comp.tsx" });
    expect(result.code).not.toContain("<div");
  });

  test("JSX 트랜스파일 (automatic-dev)", () => {
    const result = transpile('<div className="app">hello</div>', {
      filename: "app.tsx",
      jsx: "automatic-dev",
    });
    expect(result.code).toContain("jsxDEV");
  });

  test("minify 단축 옵션 (whitespace + identifiers + syntax)", () => {
    const result = transpile("const   longVariableName: number   =   1;", {
      minify: true,
    });
    expect(result.code.length).toBeLessThan("const longVariableName = 1;".length);
  });

  test("drop debugger", () => {
    const result = transpile("debugger; const x = 1;", {
      dropDebugger: true,
    });
    expect(result.code).not.toContain("debugger");
    expect(result.code).toContain("const x = 1;");
  });

  test("quotes: single", () => {
    const result = transpile('const x = "hello";', { quotes: "single" });
    expect(result.code).toContain("'hello'");
  });

  test("ascii only", () => {
    const result = transpile('const x = "한글";');
    const asciiResult = transpile('const x = "한글";', { asciiOnly: true });
    expect(asciiResult.code).toContain("\\u");
    expect(result.code).toContain("한글");
  });

  test("ES5 다운레벨링", () => {
    const result = transpile("const x = () => 1;", { target: "es5" });
    expect(result.code).not.toContain("=>");
    expect(result.code).toContain("function");
  });

  test("ES2015 다운레벨링 (template literal)", () => {
    const result = transpile("const s = `hello ${name}`;", { target: "es5" });
    expect(result.code).not.toContain("`");
  });

  test("target esnext (변환 없음)", () => {
    const result = transpile("const x = () => 1;", { target: "esnext" });
    expect(result.code).toContain("=>");
  });

  test("platform node", () => {
    const result = transpile("const x: number = 1;", { platform: "node" });
    expect(result.code).toContain("const x = 1;");
  });

  test("jsxFactory 커스텀", () => {
    const result = transpile("<div />", {
      filename: "app.tsx",
      jsx: "classic",
      jsxFactory: "h",
    });
    expect(result.code).toContain("h(");
    expect(result.code).not.toContain("React.createElement");
  });

  test("jsxImportSource 커스텀", () => {
    const result = transpile("<div />", {
      filename: "app.tsx",
      jsx: "automatic",
      jsxImportSource: "preact",
    });
    expect(result.code).toContain("preact");
  });

  test("useDefineForClassFields false", () => {
    const result = transpile("class A { x = 1; }", { useDefineForClassFields: false });
    expect(result.code).toContain("this.x");
  });

  test("init 중복 호출은 무시", () => {
    expect(() => init()).not.toThrow();
  });

  test("여러 번 호출해도 메모리 누수 없이 동작", () => {
    for (let i = 0; i < 100; i++) {
      const result = transpile(`const x${i}: number = ${i};`);
      expect(result.code).toContain(`const x${i} = ${i};`);
    }
  });
});

describe("@zts/core buildSync", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-napi-build-"));
    writeFileSync(
      join(dir, "entry.ts"),
      'import { hello } from "./util";\nconsole.log(hello("world"));',
    );
    writeFileSync(
      join(dir, "util.ts"),
      "export function hello(name: string): string { return `Hello, ${name}!`; }",
    );
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("기본 번들링", () => {
    const result = buildSync({ entryPoints: [join(dir, "entry.ts")] });
    expect(result.outputFiles.length).toBeGreaterThan(0);
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("hello");
    expect(result.outputFiles[0].text).toContain("Hello");
  });

  test("CJS 포맷", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      format: "cjs",
    });
    expect(result.outputFiles[0].text).toContain("use strict");
  });

  test("minify", () => {
    const normal = buildSync({ entryPoints: [join(dir, "entry.ts")] });
    const minified = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      minify: true,
    });
    expect(minified.outputFiles[0].text.length).toBeLessThan(normal.outputFiles[0].text.length);
  });

  test("소스맵 생성", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      sourcemap: true,
    });
    // 소스맵이 별도 outputFile로 포함
    expect(result.outputFiles.length).toBe(2);
    const smFile = result.outputFiles.find((f) => f.path.endsWith(".map"));
    expect(smFile).toBeDefined();
    const map = JSON.parse(smFile!.text);
    expect(map.version).toBe(3);
  });

  test("metafile 생성", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      metafile: true,
    });
    expect(result.metafile).toBeDefined();
    const meta = JSON.parse(result.metafile!);
    expect(meta.outputs).toBeDefined();
  });

  test("에러 반환", () => {
    const badDir = mkdtempSync(join(tmpdir(), "zts-napi-err-"));
    writeFileSync(join(badDir, "bad.ts"), 'import { x } from "./nonexistent";');
    const result = buildSync({ entryPoints: [join(badDir, "bad.ts")] });
    expect(result.errors.length).toBeGreaterThan(0);
    rmSync(badDir, { recursive: true, force: true });
  });

  test("external", () => {
    const extDir = mkdtempSync(join(tmpdir(), "zts-napi-ext-"));
    writeFileSync(join(extDir, "app.ts"), 'import React from "react";\nconsole.log(React);');
    const result = buildSync({
      entryPoints: [join(extDir, "app.ts")],
      external: ["react"],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("react");
    rmSync(extDir, { recursive: true, force: true });
  });
});

describe("@zts/core build (async)", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-napi-async-"));
    writeFileSync(
      join(dir, "entry.ts"),
      'import { hello } from "./util";\nconsole.log(hello("world"));',
    );
    writeFileSync(
      join(dir, "util.ts"),
      "export function hello(name: string): string { return `Hello, ${name}!`; }",
    );
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("비동기 번들링 (Promise)", async () => {
    const result = await build({ entryPoints: [join(dir, "entry.ts")] });
    expect(result.outputFiles.length).toBeGreaterThan(0);
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("hello");
  });

  test("비동기 minify", async () => {
    const normal = await build({ entryPoints: [join(dir, "entry.ts")] });
    const minified = await build({
      entryPoints: [join(dir, "entry.ts")],
      minify: true,
    });
    expect(minified.outputFiles[0].text.length).toBeLessThan(normal.outputFiles[0].text.length);
  });

  test("비동기 소스맵", async () => {
    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      sourcemap: true,
    });
    expect(result.outputFiles.length).toBe(2);
    const smFile = result.outputFiles.find((f) => f.path.endsWith(".map"));
    expect(smFile).toBeDefined();
  });

  test("buildSync과 동일한 결과", async () => {
    const syncResult = buildSync({ entryPoints: [join(dir, "entry.ts")] });
    const asyncResult = await build({ entryPoints: [join(dir, "entry.ts")] });
    expect(asyncResult.outputFiles[0].text).toBe(syncResult.outputFiles[0].text);
  });
});

describe("@zts/core build + plugins", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-napi-plugin-"));
    writeFileSync(join(dir, "entry.ts"), 'import css from "./style.css";\nconsole.log(css);');
    writeFileSync(
      join(dir, "app.ts"),
      'import { greet } from "./virtual:greeting";\nconsole.log(greet());',
    );
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("onResolve + onLoad 플러그인 (CSS → JS 변환)", async () => {
    const cssPlugin: ZtsPlugin = {
      name: "css-plugin",
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => ({
          path: resolve(dir, args.path),
        }));
        build.onLoad({ filter: /\.css$/ }, () => ({
          contents: 'export default "color: red";',
        }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [cssPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("color: red");
  });

  test("multiple plugins 체이닝", async () => {
    const plugin1: ZtsPlugin = {
      name: "css-resolve",
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => ({
          path: resolve(dir, args.path),
        }));
      },
    };
    const plugin2: ZtsPlugin = {
      name: "css-load",
      setup(build) {
        build.onLoad({ filter: /\.css$/ }, () => ({
          contents: 'export default "blue";',
        }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [plugin1, plugin2],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("blue");
  });

  test("onTransform 플러그인 (코드 변환)", async () => {
    const transformPlugin: ZtsPlugin = {
      name: "transform-plugin",
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (args) => ({
          code: args.code.replace("console.log", "console.warn"),
        }));
      },
    };

    const entryDir = mkdtempSync(join(tmpdir(), "zts-transform-"));
    writeFileSync(join(entryDir, "main.ts"), 'console.log("hello");');

    const result = await build({
      entryPoints: [join(entryDir, "main.ts")],
      plugins: [transformPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("console.warn");
    expect(result.outputFiles[0].text).not.toContain("console.log");
    rmSync(entryDir, { recursive: true, force: true });
  });

  test("buildSync에서 plugins 사용 시 에러", () => {
    expect(() =>
      buildSync({
        entryPoints: [join(dir, "entry.ts")],
        plugins: [{ name: "test", setup() {} }],
      }),
    ).toThrow("plugins are only supported with build()");
  });
});

// ─── 엣지케이스 테스트 ───

describe("@zts/core edge cases", () => {
  // transpile 엣지케이스
  test("매우 긴 소스코드 트랜스파일", () => {
    const lines = Array.from({ length: 10000 }, (_, i) => `export const v${i}: number = ${i};`);
    const result = transpile(lines.join("\n"));
    expect(result.code).toContain("v9999 = 9999");
  });

  test("유니코드 소스코드", () => {
    const result = transpile('const 이름: string = "한글 테스트";');
    expect(result.code).toContain("한글 테스트");
  });

  test("빈 인터페이스만 있는 파일", () => {
    const result = transpile("interface Empty {}\n");
    expect(result.code.trim()).toBe("");
  });

  test("타입만 있는 파일", () => {
    const result = transpile("type Foo = string;\ntype Bar = number;\n");
    expect(result.code.trim()).toBe("");
  });

  test("복잡한 제네릭 타입", () => {
    const result = transpile(
      "function identity<T extends Record<string, unknown>>(x: T): T { return x; }",
    );
    expect(result.code).toContain("function identity(x)");
    expect(result.code).not.toContain("<T");
  });

  test("enum + namespace 병합", () => {
    const result = transpile("enum Direction { Up, Down }\nconst d: Direction = Direction.Up;");
    expect(result.code).toContain("Direction");
  });

  test("optional chaining + nullish coalescing", () => {
    const result = transpile("const x = a?.b?.c ?? 'default';");
    expect(result.code).toContain("??");
  });

  test("decorator (experimental)", () => {
    const result = transpile(
      "@sealed\nclass Greeter {\n  greeting: string;\n  constructor(message: string) { this.greeting = message; }\n}",
      { experimentalDecorators: true },
    );
    expect(result.code).toContain("__decorate");
  });

  test("소스맵 + minify 동시 사용", () => {
    const result = transpile(
      "const longVariableName: number = 42;\nconsole.log(longVariableName);",
      {
        sourcemap: true,
        minify: true,
      },
    );
    expect(result.code.length).toBeLessThan(60);
    expect(result.map).toBeDefined();
    const map = JSON.parse(result.map!);
    expect(map.version).toBe(3);
  });

  // init 엣지케이스
  test("init 전에 transpile 호출 시 에러", () => {
    // 이미 init됨, close 후 테스트
    close();
    expect(() => transpile("const x = 1;")).toThrow("not initialized");
    init(); // 복원
  });

  test("init 전에 buildSync 호출 시 에러", () => {
    close();
    expect(() => buildSync({ entryPoints: ["/nonexistent"] })).toThrow("not initialized");
    init(); // 복원
  });

  test("init 전에 build 호출 시 에러", async () => {
    close();
    await expect(build({ entryPoints: ["/nonexistent"] })).rejects.toThrow("not initialized");
    init(); // 복원
  });

  // buildSync 엣지케이스
  test("buildSync: 빈 entryPoints 에러", () => {
    expect(() => buildSync({ entryPoints: [] })).toThrow("entryPoints is required");
  });

  test("buildSync: 존재하지 않는 파일", () => {
    const result = buildSync({ entryPoints: ["/nonexistent/file.ts"] });
    expect(result.errors.length).toBeGreaterThan(0);
  });

  test("buildSync: 모든 옵션 동시 사용", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-edge-all-opts-"));
    writeFileSync(join(dir, "index.ts"), "export const x = 1;");
    const result = buildSync({
      entryPoints: [join(dir, "index.ts")],
      format: "esm",
      platform: "browser",
      minify: true,
      sourcemap: true,
      metafile: true,
      treeShaking: true,
      keepNames: true,
      charsetUtf8: true,
      banner: "/* banner */",
      footer: "/* footer */",
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("/* banner */");
    expect(result.outputFiles[0].text).toContain("/* footer */");
    expect(result.metafile).toBeDefined();
    rmSync(dir, { recursive: true, force: true });
  });

  // build async 엣지케이스
  test("build: 빈 entryPoints 에러", async () => {
    await expect(build({ entryPoints: [] })).rejects.toThrow("entryPoints is required");
  });

  test("build: 존재하지 않는 파일", async () => {
    const result = await build({ entryPoints: ["/nonexistent/file.ts"] });
    expect(result.errors.length).toBeGreaterThan(0);
  });

  test("build: 병렬 호출", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-edge-parallel-"));
    writeFileSync(join(dir, "a.ts"), "export const a = 1;");
    writeFileSync(join(dir, "b.ts"), "export const b = 2;");

    const [resultA, resultB] = await Promise.all([
      build({ entryPoints: [join(dir, "a.ts")] }),
      build({ entryPoints: [join(dir, "b.ts")] }),
    ]);
    expect(resultA.errors.length).toBe(0);
    expect(resultB.errors.length).toBe(0);
    expect(resultA.outputFiles[0].text).toContain("a = 1");
    expect(resultB.outputFiles[0].text).toContain("b = 2");
    rmSync(dir, { recursive: true, force: true });
  });

  // 플러그인 엣지케이스
  test("plugin: null 반환 시 기본 동작", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-edge-plugin-null-"));
    writeFileSync(join(dir, "index.ts"), "export const x = 1;");

    const noopPlugin: ZtsPlugin = {
      name: "noop",
      setup(build) {
        build.onLoad({ filter: /never-match/ }, () => null);
      },
    };

    const result = await build({
      entryPoints: [join(dir, "index.ts")],
      plugins: [noopPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("x = 1");
    rmSync(dir, { recursive: true, force: true });
  });

  test("plugin: setup에서 아무 훅도 등록하지 않음", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-edge-empty-plugin-"));
    writeFileSync(join(dir, "index.ts"), "export const x = 1;");

    const result = await build({
      entryPoints: [join(dir, "index.ts")],
      plugins: [{ name: "empty", setup() {} }],
    });
    expect(result.errors.length).toBe(0);
    rmSync(dir, { recursive: true, force: true });
  });

  test("transpile: 반복 호출 1000회 메모리 안정성", () => {
    for (let i = 0; i < 1000; i++) {
      const result = transpile(`const x${i} = ${i};`);
      expect(result.code).toContain(`x${i} = ${i}`);
    }
  });
});
