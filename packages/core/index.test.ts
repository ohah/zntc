import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  init,
  transpile,
  build,
  buildSync,
  close,
  vitePlugin,
  type ZtsPlugin,
  type RollupPlugin,
} from "./index";
import { resolve } from "node:path";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
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

  test("플러그인 콜백이 throw해도 빌드가 중단되지 않음", async () => {
    const throwPlugin: ZtsPlugin = {
      name: "throw-plugin",
      setup(build) {
        build.onLoad({ filter: /never-match-anything/ }, () => {
          throw new Error("plugin error!");
        });
      },
    };

    // filter가 매치하지 않으므로 throw에 도달하지 않음 — 정상 완료
    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [throwPlugin],
    });
    // css import가 resolve 안 되므로 에러, 하지만 빌드 자체는 크래시하지 않음
    expect(result.outputFiles.length).toBeGreaterThan(0);
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

// ─── 추가 커버리지 테스트 ───

describe("@zts/core 플러그인 심화", () => {
  test("플러그인 콜백이 매치 후 throw — 에러로 전파", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-plugin-throw-"));
    writeFileSync(join(dir, "index.ts"), 'import "./data.json";');

    const throwPlugin: ZtsPlugin = {
      name: "throw-on-load",
      setup(build) {
        build.onResolve({ filter: /\.json$/ }, (args) => ({
          path: resolve(dir, args.path),
        }));
        build.onLoad({ filter: /\.json$/ }, () => {
          throw new Error("intentional plugin error");
        });
      },
    };

    // 플러그인이 throw하면 load 결과가 null → 번들러가 파일 읽기로 폴백
    // .json 파일이 없으므로 에러 발생
    const result = await build({
      entryPoints: [join(dir, "index.ts")],
      plugins: [throwPlugin],
    });
    expect(result.errors.length).toBeGreaterThan(0);
    rmSync(dir, { recursive: true, force: true });
  });

  test("다중 모듈 번들 + 플러그인", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-plugin-large-"));

    // 5개 모듈 생성
    for (let i = 0; i < 5; i++) {
      writeFileSync(join(dir, `mod${i}.ts`), `export const val${i} = ${i};`);
    }
    const imports = Array.from({ length: 5 }, (_, i) => `import { val${i} } from "./mod${i}";`);
    const usage = Array.from({ length: 5 }, (_, i) => `val${i}`).join(" + ");
    writeFileSync(join(dir, "entry.ts"), `${imports.join("\n")}\nconsole.log(${usage});`);

    let transformCount = 0;
    const countPlugin: ZtsPlugin = {
      name: "count-transforms",
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (_args) => {
          transformCount++;
          return null; // 변환 없이 카운트만
        });
      },
    };

    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [countPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("val4");
    // 최소 1회 이상 transform 호출됨
    expect(transformCount).toBeGreaterThan(0);
    rmSync(dir, { recursive: true, force: true });
  });

  test("플러그인 콜백이 undefined 반환 (null과 동일 처리)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-plugin-undef-"));
    writeFileSync(join(dir, "index.ts"), "export const x = 1;");

    const undefPlugin: ZtsPlugin = {
      name: "undef-return",
      setup(build) {
        build.onLoad({ filter: /\.ts$/ }, () => undefined as any);
      },
    };

    const result = await build({
      entryPoints: [join(dir, "index.ts")],
      plugins: [undefPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("x = 1");
    rmSync(dir, { recursive: true, force: true });
  });

  test("멀티스레드: 10개 모듈 + onTransform 플러그인 (#985)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-plugin-mt-"));
    for (let i = 0; i < 10; i++) {
      writeFileSync(join(dir, `mod${i}.ts`), `export const val${i} = ${i};`);
    }
    const imports = Array.from({ length: 10 }, (_, i) => `import { val${i} } from "./mod${i}";`);
    const usage = Array.from({ length: 10 }, (_, i) => `val${i}`).join(" + ");
    writeFileSync(join(dir, "entry.ts"), `${imports.join("\n")}\nconsole.log(${usage});`);

    let callCount = 0;
    const countPlugin: ZtsPlugin = {
      name: "count",
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (_args) => {
          callCount++;
          return null;
        });
      },
    };

    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [countPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("val9");
    expect(callCount).toBeGreaterThan(0);
    rmSync(dir, { recursive: true, force: true });
  });

  test("멀티스레드: 동시 resolveId + load + transform (#985)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-plugin-mt2-"));
    writeFileSync(join(dir, "entry.ts"), 'import css from "./style.css";\nconsole.log(css);');

    const hooksCalled: string[] = [];
    const multiHookPlugin: ZtsPlugin = {
      name: "multi-hook",
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => {
          hooksCalled.push("resolve");
          return { path: resolve(dir, args.path) };
        });
        build.onLoad({ filter: /\.css$/ }, () => {
          hooksCalled.push("load");
          return { contents: 'export default "red";' };
        });
        build.onTransform({ filter: /\.ts$/ }, (_args) => {
          hooksCalled.push("transform");
          return null;
        });
      },
    };

    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [multiHookPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("red");
    expect(hooksCalled).toContain("resolve");
    expect(hooksCalled).toContain("load");
    expect(hooksCalled).toContain("transform");
    rmSync(dir, { recursive: true, force: true });
  });

  test("멀티스레드: 플러그인 + minify + sourcemap 동시 (#985)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-plugin-mt3-"));
    for (let i = 0; i < 5; i++) {
      writeFileSync(join(dir, `mod${i}.ts`), `export const val${i} = ${i};`);
    }
    const imports = Array.from({ length: 5 }, (_, i) => `import { val${i} } from "./mod${i}";`);
    writeFileSync(join(dir, "entry.ts"), `${imports.join("\n")}\nconsole.log(val0);`);

    const noopPlugin: ZtsPlugin = {
      name: "noop",
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, () => null);
      },
    };

    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [noopPlugin],
      minify: true,
      sourcemap: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBe(2); // js + map
    rmSync(dir, { recursive: true, force: true });
  });
});

describe("@zts/core 번들 포맷/플랫폼", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-format-"));
    writeFileSync(join(dir, "index.ts"), 'export const greeting = "hello";\nexport default 42;');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("IIFE 포맷", () => {
    const result = buildSync({
      entryPoints: [join(dir, "index.ts")],
      format: "iife",
    });
    expect(result.errors.length).toBe(0);
    // IIFE는 즉시 실행 함수로 감싸짐
    expect(
      result.outputFiles[0].text.includes("(function") ||
        result.outputFiles[0].text.includes("(() =>") ||
        result.outputFiles[0].text.includes("(()"),
    ).toBe(true);
  });

  test("IIFE + globalName", () => {
    const result = buildSync({
      entryPoints: [join(dir, "index.ts")],
      format: "iife",
      globalName: "MyLib",
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("MyLib");
  });

  test("platform=node", () => {
    const result = buildSync({
      entryPoints: [join(dir, "index.ts")],
      platform: "node",
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("greeting");
  });

  test("platform=react-native", () => {
    const result = buildSync({
      entryPoints: [join(dir, "index.ts")],
      platform: "react-native",
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("greeting");
  });

  test("ESM import/export 보존", () => {
    const result = buildSync({
      entryPoints: [join(dir, "index.ts")],
      format: "esm",
    });
    expect(result.errors.length).toBe(0);
    // ESM은 export 키워드 포함
    expect(result.outputFiles[0].text).toContain("greeting");
  });
});

describe("@zts/core build 옵션 조합", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-combo-"));
    writeFileSync(
      join(dir, "index.ts"),
      'import { helper } from "./util";\nconsole.log(helper());',
    );
    writeFileSync(join(dir, "util.ts"), "export function helper() { return 42; }");
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("minifyWhitespace만 적용", () => {
    const result = buildSync({
      entryPoints: [join(dir, "index.ts")],
      minifyWhitespace: true,
    });
    expect(result.errors.length).toBe(0);
    // 줄바꿈/공백이 줄어듦
    expect(result.outputFiles[0].text.split("\n").length).toBeLessThan(20);
  });

  test("minifyIdentifiers 적용 시 출력 크기 감소", () => {
    const normal = buildSync({ entryPoints: [join(dir, "index.ts")] });
    const minified = buildSync({
      entryPoints: [join(dir, "index.ts")],
      minifyIdentifiers: true,
    });
    expect(minified.errors.length).toBe(0);
    // 식별자 축소로 출력이 줄어들거나 동일 (scope hoist 인라인 시)
    expect(minified.outputFiles[0].text.length).toBeLessThanOrEqual(
      normal.outputFiles[0].text.length,
    );
  });

  test("sourcemap + minify + metafile 동시", () => {
    const result = buildSync({
      entryPoints: [join(dir, "index.ts")],
      minify: true,
      sourcemap: true,
      metafile: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBe(2); // js + map
    expect(result.metafile).toBeDefined();
    const map = JSON.parse(result.outputFiles.find((f) => f.path.endsWith(".map"))!.text);
    expect(map.version).toBe(3);
  });

  test("treeShaking=false로 미사용 export 보존", () => {
    const tsDir = mkdtempSync(join(tmpdir(), "zts-tree-"));
    writeFileSync(join(tsDir, "index.ts"), 'import { used } from "./lib";\nconsole.log(used);');
    writeFileSync(join(tsDir, "lib.ts"), "export const used = 1;\nexport const unused = 2;");

    const withTree = buildSync({
      entryPoints: [join(tsDir, "index.ts")],
      treeShaking: true,
    });
    const withoutTree = buildSync({
      entryPoints: [join(tsDir, "index.ts")],
      treeShaking: false,
    });
    // tree-shaking 끄면 unused도 포함
    expect(withoutTree.outputFiles[0].text).toContain("unused");
    // tree-shaking 켜면 unused 제거 (scope hoist 활성화 시)
    expect(withTree.outputFiles[0].text).not.toContain("unused");
    rmSync(tsDir, { recursive: true, force: true });
  });

  test("JSX automatic + build", () => {
    const jsxDir = mkdtempSync(join(tmpdir(), "zts-jsx-build-"));
    writeFileSync(join(jsxDir, "app.tsx"), "export default () => <div>hello</div>;");

    const result = buildSync({
      entryPoints: [join(jsxDir, "app.tsx")],
      jsx: "automatic",
      jsxInJs: true,
      external: ["react/jsx-runtime"],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("jsx-runtime");
    rmSync(jsxDir, { recursive: true, force: true });
  });

  test("Flow 파일 번들링", () => {
    const flowDir = mkdtempSync(join(tmpdir(), "zts-flow-build-"));
    writeFileSync(
      join(flowDir, "index.js"),
      '// @flow\nfunction foo(x: string): number { return x.length; }\nconsole.log(foo("test"));',
    );

    const result = buildSync({
      entryPoints: [join(flowDir, "index.js")],
      flow: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain(": string");
    expect(result.outputFiles[0].text).not.toContain(": number");
    rmSync(flowDir, { recursive: true, force: true });
  });

  test("build async: 동시 5개 호출", async () => {
    const results = await Promise.all(
      Array.from({ length: 5 }, () => build({ entryPoints: [join(dir, "index.ts")] })),
    );
    for (const r of results) {
      expect(r.errors.length).toBe(0);
      expect(r.outputFiles[0].text).toContain("helper");
    }
  });
});

// ─── ES2023 + hashbang ───

describe("@zts/core ES2023/hashbang", () => {
  test("target es5: hashbang이 제거됨", () => {
    const result = transpile("#!/usr/bin/env node\nconsole.log('hello');", {
      target: "es5",
    });
    expect(result.code).not.toContain("#!");
    expect(result.code).toContain("hello");
  });

  test("target es2022: hashbang이 제거됨 (es2022 < es2023)", () => {
    const result = transpile("#!/usr/bin/env node\nconst x = 1;", {
      target: "es2022",
    });
    expect(result.code).not.toContain("#!");
    expect(result.code).toContain("x = 1");
  });

  test("target es2023: hashbang이 유지됨", () => {
    const result = transpile("#!/usr/bin/env node\nconst x = 1;", {
      target: "es2023",
    });
    expect(result.code).toContain("#!/usr/bin/env node");
    expect(result.code).toContain("x = 1");
  });

  test("target esnext: hashbang이 유지됨", () => {
    const result = transpile("#!/usr/bin/env node\nconst x = 1;", {
      target: "esnext",
    });
    expect(result.code).toContain("#!/usr/bin/env node");
  });

  test("hashbang 없는 파일에서 es2022 타겟 — 정상 동작", () => {
    const result = transpile("const x: number = 1;", { target: "es2022" });
    expect(result.code).toContain("const x = 1");
  });

  test("target 미지정: hashbang이 유지됨 (기본 esnext)", () => {
    const result = transpile("#!/usr/bin/env node\nconst x = 1;");
    expect(result.code).toContain("#!/usr/bin/env node");
  });

  test("es2023 타겟 번들링", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-es2023-build-"));
    writeFileSync(join(dir, "index.ts"), "#!/usr/bin/env node\nconsole.log(1);");
    // buildSync에 target 옵션이 없으므로 transpile로 테스트
    const result = transpile(readFileSync(join(dir, "index.ts"), "utf8"), {
      target: "es2023",
    });
    expect(result.code).toContain("#!/usr/bin/env node");
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── define/alias 옵션 ───

describe("@zts/core define/alias", () => {
  test("define: 글로벌 상수 치환", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-define-"));
    writeFileSync(
      join(dir, "index.ts"),
      "console.log(process.env.NODE_ENV);\nconsole.log(__DEV__);",
    );

    const result = buildSync({
      entryPoints: [join(dir, "index.ts")],
      define: {
        "process.env.NODE_ENV": '"production"',
        __DEV__: "false",
      },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("production");
    expect(result.outputFiles[0].text).toContain("false");
    expect(result.outputFiles[0].text).not.toContain("process.env.NODE_ENV");
    rmSync(dir, { recursive: true, force: true });
  });

  test("alias: import 경로 치환", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-alias-"));
    writeFileSync(join(dir, "real.ts"), "export const x = 42;");
    writeFileSync(join(dir, "index.ts"), 'import { x } from "@alias/mod";\nconsole.log(x);');

    const result = buildSync({
      entryPoints: [join(dir, "index.ts")],
      alias: { "@alias/mod": join(dir, "real.ts") },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("42");
    rmSync(dir, { recursive: true, force: true });
  });

  test("define: async build에서도 동작", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-define-async-"));
    writeFileSync(join(dir, "index.ts"), "console.log(VERSION);");

    const result = await build({
      entryPoints: [join(dir, "index.ts")],
      define: { VERSION: '"1.0.0"' },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("1.0.0");
    rmSync(dir, { recursive: true, force: true });
  });

  test("빈 define/alias 객체 → 무시", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-empty-define-"));
    writeFileSync(join(dir, "index.ts"), "export const x = 1;");

    const result = buildSync({
      entryPoints: [join(dir, "index.ts")],
      define: {},
      alias: {},
    });
    expect(result.errors.length).toBe(0);
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── Vite/Rollup 플러그인 어댑터 ───

describe("vitePlugin 어댑터", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-vite-adapter-"));
    writeFileSync(join(dir, "entry.ts"), 'import css from "./style.css";\nconsole.log(css);');
    writeFileSync(join(dir, "app.ts"), 'import { greet } from "./util";\nconsole.log(greet());');
    writeFileSync(join(dir, "util.ts"), "export function greet(): string { return 'Hello!'; }");
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test("resolveId 훅 — 문자열 반환", async () => {
    const plugin: RollupPlugin = {
      name: "rollup-resolve-string",
      resolveId(source) {
        if (source.endsWith(".css")) return resolve(dir, source);
        return null;
      },
      load(id) {
        if (id.endsWith(".css")) return 'export default "red";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("red");
  });

  test("resolveId 훅 — { id } 객체 반환", async () => {
    const plugin: RollupPlugin = {
      name: "rollup-resolve-object",
      resolveId(source) {
        if (source.endsWith(".css")) return { id: resolve(dir, source) };
        return null;
      },
      load(id) {
        if (id.endsWith(".css")) return { code: 'export default "blue";' };
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("blue");
  });

  test("load 훅 — 문자열 반환", async () => {
    const plugin: RollupPlugin = {
      name: "rollup-load-string",
      resolveId(source) {
        if (source.endsWith(".css")) return resolve(dir, source);
        return null;
      },
      load(id) {
        if (id.endsWith(".css")) return 'export default "from-string";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("from-string");
  });

  test("load 훅 — { code } 객체 반환", async () => {
    const plugin: RollupPlugin = {
      name: "rollup-load-object",
      resolveId(source) {
        if (source.endsWith(".css")) return resolve(dir, source);
        return null;
      },
      load(id) {
        if (id.endsWith(".css")) return { code: 'export default "from-object";' };
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("from-object");
  });

  test("transform 훅 — 문자열 반환", async () => {
    const plugin: RollupPlugin = {
      name: "rollup-transform-string",
      transform(code, _id) {
        return code.replace("Hello!", "Transformed!");
      },
    };

    const result = await build({
      entryPoints: [join(dir, "app.ts")],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("Transformed!");
  });

  test("transform 훅 — { code } 객체 반환", async () => {
    const plugin: RollupPlugin = {
      name: "rollup-transform-object",
      transform(code, _id) {
        return { code: code.replace("Hello!", "ObjectTransformed!") };
      },
    };

    const result = await build({
      entryPoints: [join(dir, "app.ts")],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("ObjectTransformed!");
  });

  test("transform 훅 — null 반환 (통과)", async () => {
    const plugin: RollupPlugin = {
      name: "rollup-transform-null",
      transform() {
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, "app.ts")],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("Hello!");
  });

  test("여러 Rollup 플러그인 조합", async () => {
    const resolverPlugin: RollupPlugin = {
      name: "resolver",
      resolveId(source) {
        if (source.endsWith(".css")) return resolve(dir, source);
        return null;
      },
    };

    const loaderPlugin: RollupPlugin = {
      name: "loader",
      load(id) {
        if (id.endsWith(".css")) return 'export default "multi-plugin";';
        return null;
      },
    };

    const transformerPlugin: RollupPlugin = {
      name: "transformer",
      transform(code, _id) {
        return code.replace("multi-plugin", "MULTI-TRANSFORMED");
      },
    };

    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [
        vitePlugin(resolverPlugin),
        vitePlugin(loaderPlugin),
        vitePlugin(transformerPlugin),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("MULTI-TRANSFORMED");
  });

  test("ZTS 플러그인과 Vite 플러그인 혼합", async () => {
    const nativePlugin: ZtsPlugin = {
      name: "native-resolve",
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => ({
          path: resolve(dir, args.path),
        }));
      },
    };

    const rollupLoader: RollupPlugin = {
      name: "rollup-loader",
      load(id) {
        if (id.endsWith(".css")) return 'export default "mixed";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [nativePlugin, vitePlugin(rollupLoader)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("mixed");
  });

  test("훅이 없는 빈 Rollup 플러그인", async () => {
    const emptyPlugin: RollupPlugin = { name: "empty" };
    const result = await build({
      entryPoints: [join(dir, "app.ts")],
      plugins: [vitePlugin(emptyPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("Hello!");
  });

  test("resolveId에서 undefined/void 반환", async () => {
    const plugin: RollupPlugin = {
      name: "void-return",
      resolveId() {
        // void — 아무것도 반환하지 않음
      },
    };
    const result = await build({
      entryPoints: [join(dir, "app.ts")],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
  });

  test("실전 패턴: JSON 플러그인 (Rollup 스타일)", async () => {
    const jsonDir = mkdtempSync(join(tmpdir(), "zts-vite-json-"));
    writeFileSync(join(jsonDir, "data.json"), '{"name":"test","version":"1.0"}');
    writeFileSync(
      join(jsonDir, "index.ts"),
      'import data from "./data.json";\nconsole.log(data.name);',
    );

    const jsonPlugin: RollupPlugin = {
      name: "rollup-json",
      resolveId(source, importer) {
        if (source.endsWith(".json") && importer) {
          return resolve(jsonDir, source);
        }
        return null;
      },
      load(id) {
        if (id.endsWith(".json")) {
          const json = readFileSync(id, "utf8");
          return `export default ${json};`;
        }
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(jsonDir, "index.ts")],
      plugins: [vitePlugin(jsonPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("test");
    expect(result.outputFiles[0].text).toContain("1.0");
    rmSync(jsonDir, { recursive: true, force: true });
  });

  test("실전 패턴: 환경 변수 치환 플러그인", async () => {
    const envDir = mkdtempSync(join(tmpdir(), "zts-vite-env-"));
    writeFileSync(join(envDir, "index.ts"), "console.log(import.meta.env.MODE);");

    const envPlugin: RollupPlugin = {
      name: "rollup-env",
      transform(code, _id) {
        return code.replace("import.meta.env.MODE", '"production"');
      },
    };

    const result = await build({
      entryPoints: [join(envDir, "index.ts")],
      plugins: [vitePlugin(envPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("production");
    rmSync(envDir, { recursive: true, force: true });
  });

  test("실전 패턴: YAML 로더 플러그인", async () => {
    const yamlDir = mkdtempSync(join(tmpdir(), "zts-vite-yaml-"));
    writeFileSync(join(yamlDir, "config.yaml"), "name: test\nversion: 2.0");
    writeFileSync(
      join(yamlDir, "index.ts"),
      'import config from "./config.yaml";\nconsole.log(config);',
    );

    const yamlPlugin: RollupPlugin = {
      name: "rollup-yaml",
      resolveId(source, importer) {
        if (source.endsWith(".yaml") && importer) return resolve(yamlDir, source);
        return null;
      },
      load(id) {
        if (id.endsWith(".yaml")) {
          const content = readFileSync(id, "utf8");
          const obj: Record<string, string> = {};
          for (const line of content.split("\n")) {
            const [k, v] = line.split(": ");
            if (k && v) obj[k.trim()] = v.trim();
          }
          return `export default ${JSON.stringify(obj)};`;
        }
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(yamlDir, "index.ts")],
      plugins: [vitePlugin(yamlPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("test");
    expect(result.outputFiles[0].text).toContain("2.0");
    rmSync(yamlDir, { recursive: true, force: true });
  });

  test("실전 패턴: SVG → React 컴포넌트 플러그인", async () => {
    const svgDir = mkdtempSync(join(tmpdir(), "zts-vite-svg-"));
    writeFileSync(join(svgDir, "icon.svg"), '<svg><circle r="10"/></svg>');
    writeFileSync(join(svgDir, "index.tsx"), 'import Icon from "./icon.svg";\nconsole.log(Icon);');

    const svgPlugin: RollupPlugin = {
      name: "rollup-svg-react",
      resolveId(source, importer) {
        if (source.endsWith(".svg") && importer) return resolve(svgDir, source);
        return null;
      },
      load(id) {
        if (id.endsWith(".svg")) {
          const svg = readFileSync(id, "utf8");
          return `export default function SvgIcon() { return "${svg.replace(/"/g, '\\"')}"; }`;
        }
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(svgDir, "index.tsx")],
      plugins: [vitePlugin(svgPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("SvgIcon");
    expect(result.outputFiles[0].text).toContain("circle");
    rmSync(svgDir, { recursive: true, force: true });
  });

  test("실전 패턴: GraphQL 쿼리 로더", async () => {
    const gqlDir = mkdtempSync(join(tmpdir(), "zts-vite-gql-"));
    writeFileSync(join(gqlDir, "query.graphql"), "query GetUser { user { name } }");
    writeFileSync(
      join(gqlDir, "index.ts"),
      'import query from "./query.graphql";\nconsole.log(query);',
    );

    const gqlPlugin: RollupPlugin = {
      name: "rollup-graphql",
      resolveId(source, importer) {
        if (source.endsWith(".graphql") && importer) return resolve(gqlDir, source);
        return null;
      },
      load(id) {
        if (id.endsWith(".graphql")) {
          const content = readFileSync(id, "utf8");
          return `export default ${JSON.stringify(content)};`;
        }
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(gqlDir, "index.ts")],
      plugins: [vitePlugin(gqlPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("GetUser");
    rmSync(gqlDir, { recursive: true, force: true });
  });

  test("실전 패턴: 코드 내 console.log 자동 제거 transform", async () => {
    const stripDir = mkdtempSync(join(tmpdir(), "zts-vite-strip-"));
    writeFileSync(
      join(stripDir, "index.ts"),
      'console.log("debug");\nconst x = 1;\nconsole.log("also debug");\nconsole.warn("keep");',
    );

    const stripPlugin: RollupPlugin = {
      name: "rollup-strip-console-log",
      transform(code, _id) {
        return code.replace(/console\.log\([^)]*\);?\n?/g, "");
      },
    };

    const result = await build({
      entryPoints: [join(stripDir, "index.ts")],
      plugins: [vitePlugin(stripPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain("console.log");
    expect(result.outputFiles[0].text).toContain("console.warn");
    expect(result.outputFiles[0].text).toContain("x = 1");
    rmSync(stripDir, { recursive: true, force: true });
  });

  test("실전 패턴: 다중 vitePlugin transform 체이닝", async () => {
    const chainDir = mkdtempSync(join(tmpdir(), "zts-vite-chain-"));
    writeFileSync(join(chainDir, "index.ts"), 'const msg = "HELLO_WORLD";');

    // 첫 번째 플러그인: HELLO → Hello
    const lowercasePlugin: RollupPlugin = {
      name: "lowercase-first",
      transform(code) {
        return code.replace("HELLO", "Hello");
      },
    };

    // 두 번째 플러그인: _WORLD → _World (첫 번째 결과를 입력으로 받음)
    const capitalizePlugin: RollupPlugin = {
      name: "capitalize-second",
      transform(code) {
        return code.replace("_WORLD", "_World");
      },
    };

    const result = await build({
      entryPoints: [join(chainDir, "index.ts")],
      plugins: [vitePlugin(lowercasePlugin), vitePlugin(capitalizePlugin)],
    });
    expect(result.errors.length).toBe(0);
    // 두 플러그인의 transform이 순차 체이닝되어야 함
    expect(result.outputFiles[0].text).toContain("Hello_World");
    rmSync(chainDir, { recursive: true, force: true });
  });

  test("실전 패턴: 3개 플러그인 transform 체이닝", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-vite-chain3-"));
    writeFileSync(join(dir, "index.ts"), 'const x = "AAA_BBB_CCC";');

    const result = await build({
      entryPoints: [join(dir, "index.ts")],
      plugins: [
        vitePlugin({ name: "p1", transform: (code) => code.replace("AAA", "aaa") }),
        vitePlugin({ name: "p2", transform: (code) => code.replace("BBB", "bbb") }),
        vitePlugin({ name: "p3", transform: (code) => code.replace("CCC", "ccc") }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("aaa_bbb_ccc");
    rmSync(dir, { recursive: true, force: true });
  });

  test("vitePlugin: resolveId에 importer가 올바르게 전달됨", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-vite-importer-"));
    writeFileSync(join(dir, "entry.ts"), 'import x from "./data.custom";\nconsole.log(x);');

    let receivedImporter: string | null | undefined = undefined;
    const plugin: RollupPlugin = {
      name: "check-importer",
      resolveId(source, importer) {
        if (source.endsWith(".custom")) {
          receivedImporter = importer ?? null;
          return resolve(dir, source);
        }
        return null;
      },
      load(id) {
        if (id.endsWith(".custom")) return 'export default "custom-data";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    // importer는 entry.ts의 절대 경로여야 함
    expect(receivedImporter).toContain("entry.ts");
    rmSync(dir, { recursive: true, force: true });
  });

  test("vitePlugin: transform이 { code, map } 반환 시 map 무시", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-vite-map-"));
    writeFileSync(join(dir, "index.ts"), "const x = 1;");

    const plugin: RollupPlugin = {
      name: "with-map",
      transform(code) {
        return { code: code.replace("1", "42"), map: { version: 3, mappings: "" } };
      },
    };

    const result = await build({
      entryPoints: [join(dir, "index.ts")],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("42");
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── 옵션 조합 심화 테스트 ───

describe("@zts/core 옵션 조합 심화", () => {
  test("hashbang + minify", () => {
    const result = transpile(
      "#!/usr/bin/env node\nconst longVariableName = 42;\nconsole.log(longVariableName);",
      {
        minify: true,
        target: "es2023",
      },
    );
    expect(result.code).toContain("#!/usr/bin/env node");
    expect(result.code.length).toBeLessThan(80);
  });

  test("hashbang + sourcemap + es2022 (hashbang 제거됨)", () => {
    const result = transpile("#!/usr/bin/env node\nconst x = 1;", {
      sourcemap: true,
      target: "es2022",
    });
    expect(result.code).not.toContain("#!");
    expect(result.map).toBeDefined();
  });

  test("buildSync + define + alias + sourcemap 동시", () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-combo-all-"));
    writeFileSync(join(dir, "real.ts"), "export const val = 42;");
    writeFileSync(
      join(dir, "index.ts"),
      'import { val } from "@mod";\nconsole.log(val, __VERSION__);',
    );

    const result = buildSync({
      entryPoints: [join(dir, "index.ts")],
      define: { __VERSION__: '"1.0"' },
      alias: { "@mod": join(dir, "real.ts") },
      sourcemap: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("42");
    expect(result.outputFiles[0].text).toContain("1.0");
    expect(result.outputFiles.length).toBe(2); // js + map
    rmSync(dir, { recursive: true, force: true });
  });

  test("transpile: 모든 ES 타겟 순회 (es5~esnext)", () => {
    const targets = [
      "es5",
      "es2015",
      "es2016",
      "es2017",
      "es2018",
      "es2019",
      "es2020",
      "es2021",
      "es2022",
      "es2023",
      "es2024",
      "es2025",
      "esnext",
    ] as const;
    for (const target of targets) {
      const result = transpile("const x = () => 1;", { target });
      expect(result.code.length).toBeGreaterThan(0);
      if (target === "es5") {
        // es5에서만 arrow function 다운레벨
        expect(result.code).not.toContain("=>");
      } else {
        // es2015+에서는 arrow function 유지
        expect(result.code).toContain("=>");
      }
    }
  });

  test("build + platform=node + jsx=automatic + plugins (실제 코드 변환)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-combo-node-jsx-"));
    writeFileSync(join(dir, "app.tsx"), "export default () => <div>hello</div>;");

    const result = await build({
      entryPoints: [join(dir, "app.tsx")],
      platform: "node",
      jsx: "automatic",
      external: ["react/jsx-runtime"],
      plugins: [
        {
          name: "replace-transform",
          setup(build) {
            // 주석이 아닌 실제 코드 변환 (주석은 파서에서 제거됨)
            build.onTransform({ filter: /\.tsx$/ }, (args) => ({
              code: args.code.replace("hello", "transformed"),
            }));
          },
        },
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("transformed");
    expect(result.outputFiles[0].text).toContain("jsx-runtime");
    rmSync(dir, { recursive: true, force: true });
  });

  test("build + define + plugins (define은 NAPI, plugin은 JS)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "zts-define-plugin-"));
    writeFileSync(
      join(dir, "index.ts"),
      'import css from "./style.css";\nconsole.log(__MODE__, css);',
    );

    const cssPlugin: ZtsPlugin = {
      name: "css",
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.css$/ }, () => ({ contents: 'export default "red";' }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, "index.ts")],
      define: { __MODE__: '"production"' },
      plugins: [cssPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("production");
    expect(result.outputFiles[0].text).toContain("red");
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── 새 BuildOptions 테스트 ───

describe("BuildOptions: 누락 옵션 노출 (#1005)", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-build-opts-"));
    writeFileSync(join(dir, "entry.ts"), "export const fn = () => 1;");
    writeFileSync(join(dir, "data.txt"), "hello text");
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("target: es5 → arrow function이 function으로 변환됨", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      target: "es5",
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain("=>");
    expect(result.outputFiles[0].text).toContain("function");
  });

  test("target: esnext → arrow function 유지", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      target: "esnext",
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("=>");
  });

  test("loader: .txt=text → 텍스트 파일이 문자열로 export됨", () => {
    writeFileSync(join(dir, "import-txt.ts"), 'import txt from "./data.txt";\nconsole.log(txt);');
    const result = buildSync({
      entryPoints: [join(dir, "import-txt.ts")],
      loader: { ".txt": "text" },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("hello text");
  });

  test("resolveExtensions: 커스텀 확장자 순서가 적용됨", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      resolveExtensions: [".ts", ".tsx", ".js"],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });

  test("mainFields: 커스텀 필드 순서가 적용됨", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      mainFields: ["module", "main"],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });

  test("conditions: 커스텀 exports 조건이 적용됨", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      conditions: ["import", "default"],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });

  test("write + outdir: 디스크에 파일이 기록됨", () => {
    const outdir = join(dir, "out-dir");
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      outdir,
      write: true,
    });
    expect(result.errors.length).toBe(0);
    const written = readFileSync(join(outdir, "bundle.js"), "utf-8");
    expect(written).toContain("fn");
    rmSync(outdir, { recursive: true, force: true });
  });

  test("outfile: 단일 파일 출력 경로 지정", () => {
    const outfile = join(dir, "custom-out", "my-bundle.js");
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      outfile,
    });
    expect(result.errors.length).toBe(0);
    const written = readFileSync(outfile, "utf-8");
    expect(written).toContain("fn");
    rmSync(join(dir, "custom-out"), { recursive: true, force: true });
  });

  test("outdir 지정 시 write 자동 true", () => {
    const outdir = join(dir, "auto-write");
    buildSync({
      entryPoints: [join(dir, "entry.ts")],
      outdir,
    });
    const written = readFileSync(join(outdir, "bundle.js"), "utf-8");
    expect(written).toContain("fn");
    rmSync(outdir, { recursive: true, force: true });
  });

  test("write: false → 디스크에 기록하지 않음", () => {
    const outdir = join(dir, "no-write");
    buildSync({
      entryPoints: [join(dir, "entry.ts")],
      outdir,
      write: false,
    });
    expect(() => readFileSync(join(outdir, "bundle.js"))).toThrow();
  });

  test("outfile + sourcemap: 소스맵이 outfile 옆에 생성됨", () => {
    const outfile = join(dir, "sm-out", "bundle.js");
    buildSync({
      entryPoints: [join(dir, "entry.ts")],
      outfile,
      sourcemap: true,
    });
    const mapContent = readFileSync(outfile + ".map", "utf-8");
    expect(mapContent).toContain("mappings");
    rmSync(join(dir, "sm-out"), { recursive: true, force: true });
  });
});

// ─── vitePlugin async 훅 테스트 (#1007) ───

describe("vitePlugin async 훅 지원", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-async-plugin-"));
    writeFileSync(join(dir, "entry.ts"), 'import val from "./data.custom";\nconsole.log(val);');
    writeFileSync(join(dir, "data.custom"), "CUSTOM_DATA");
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("async load 훅", async () => {
    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [
        vitePlugin({
          name: "async-loader",
          async load(id) {
            if (id.endsWith(".custom")) {
              await new Promise((r) => setTimeout(r, 10));
              return { code: 'export default "ASYNC_LOADED";' };
            }
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("ASYNC_LOADED");
  });

  test("async resolveId 훅", async () => {
    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [
        vitePlugin({
          name: "async-resolver",
          async resolveId(source) {
            if (source.endsWith(".custom")) {
              await new Promise((r) => setTimeout(r, 10));
              return join(dir, "data.custom");
            }
          },
          load(id) {
            if (id.endsWith(".custom")) {
              return { code: 'export default "RESOLVED";' };
            }
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("RESOLVED");
  });

  test("async transform 훅", async () => {
    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [
        vitePlugin({
          name: "async-transformer",
          async transform(code, id) {
            if (id.endsWith(".ts")) {
              await new Promise((r) => setTimeout(r, 10));
              return code.replace("console.log", "console.info");
            }
          },
        }),
        vitePlugin({
          name: "custom-loader",
          load(id) {
            if (id.endsWith(".custom")) return { code: 'export default "X";' };
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("console.info");
    expect(result.outputFiles[0].text).not.toContain("console.log");
  });

  test("동기 + 비동기 훅 혼합", async () => {
    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [
        vitePlugin({
          name: "sync-plugin",
          load(id) {
            if (id.endsWith(".custom")) return { code: 'export default "SYNC";' };
          },
        }),
        vitePlugin({
          name: "async-plugin",
          async transform(code) {
            await new Promise((r) => setTimeout(r, 5));
            return code.replace("console.log", "console.warn");
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("SYNC");
    expect(result.outputFiles[0].text).toContain("console.warn");
  });
});

// ─── renderChunk/generateBundle 훅 테스트 (#1004) ───

describe("renderChunk/generateBundle 훅", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-chunk-hooks-"));
    writeFileSync(join(dir, "entry.ts"), "export const x = 1;");
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("renderChunk: 청크 코드 후처리", async () => {
    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [
        {
          name: "chunk-banner",
          setup(build) {
            build.onRenderChunk({ filter: /.*/ }, (args) => {
              return { code: `/* CHUNK: ${args.chunk} */\n${args.code}` };
            });
          },
        },
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("/* CHUNK:");
    expect(result.outputFiles[0].text).toContain("x = 1");
  });

  test("renderChunk via vitePlugin", async () => {
    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [
        vitePlugin({
          name: "vite-chunk",
          renderChunk(code) {
            return code.replace("x = 1", "x = 42");
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("x = 42");
  });

  test("async renderChunk", async () => {
    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [
        vitePlugin({
          name: "async-chunk",
          async renderChunk(code) {
            await new Promise((r) => setTimeout(r, 5));
            return `/* ASYNC */\n${code}`;
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("/* ASYNC */");
  });

  test("generateBundle: 번들 완료 콜백", async () => {
    const collected: string[] = [];
    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [
        {
          name: "bundle-inspector",
          setup(build) {
            build.onGenerateBundle((outputs) => {
              for (const f of outputs) {
                collected.push(f.path);
              }
            });
          },
        },
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(collected.length).toBeGreaterThan(0);
  });

  test("generateBundle via vitePlugin", async () => {
    let called = false;
    await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [
        vitePlugin({
          name: "vite-generate",
          generateBundle(outputs) {
            called = true;
            expect(outputs.length).toBeGreaterThan(0);
          },
        }),
      ],
    });
    expect(called).toBe(true);
  });

  test("renderChunk 체이닝: 2개 플러그인 순차 적용", async () => {
    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [
        vitePlugin({
          name: "chunk-step1",
          renderChunk(code) {
            return code.replace("x = 1", "x = 10");
          },
        }),
        vitePlugin({
          name: "chunk-step2",
          renderChunk(code) {
            return code.replace("x = 10", "x = 100");
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("x = 100");
    expect(result.outputFiles[0].text).not.toContain("x = 1;");
  });

  test("async generateBundle", async () => {
    let called = false;
    await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [
        vitePlugin({
          name: "async-generate",
          async generateBundle(outputs) {
            await new Promise((r) => setTimeout(r, 5));
            called = true;
            expect(outputs.length).toBeGreaterThan(0);
          },
        }),
      ],
    });
    expect(called).toBe(true);
  });

  test("generateBundle: 에러가 throw되어도 빌드 성공", async () => {
    const result = await build({
      entryPoints: [join(dir, "entry.ts")],
      plugins: [
        vitePlugin({
          name: "error-generate",
          generateBundle() {
            throw new Error("intentional error");
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });
});

describe("BuildOptions: 엣지 케이스", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-edge-"));
    writeFileSync(join(dir, "entry.ts"), "export const x = () => 1;");
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("target: 잘못된 값은 무시 (변환 없음)", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      target: "es2099" as any,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("=>");
  });

  test("loader: 잘못된 값은 무시", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      loader: { ".ts": "invalid_loader" },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });
});

// ─── 배치 E: S급 옵션 노출 테스트 ───

describe("배치 E: S급 BuildOptions", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-batch-e-"));
    writeFileSync(join(dir, "entry.ts"), 'DEV: { console.log("dev only"); }\nexport const x = 1;');
    writeFileSync(
      join(dir, "pure-test.ts"),
      'import { pureUtil } from "./util";\nconst unused = pureUtil();\nexport const y = 2;',
    );
    writeFileSync(join(dir, "util.ts"), "export function pureUtil() { return 42; }");
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("packagesExternal: bare import를 external 처리", () => {
    writeFileSync(join(dir, "ext-entry.ts"), 'import React from "react";\nexport default React;');
    const result = buildSync({
      entryPoints: [join(dir, "ext-entry.ts")],
      packagesExternal: true,
    });
    expect(result.errors.length).toBe(0);
    // react가 external이므로 번들에 포함되지 않고 import 문이 유지됨
    expect(result.outputFiles[0].text).toMatch(/import.*react|require.*react/);
  });

  test("dropLabels: DEV 라벨 제거", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      dropLabels: ["DEV"],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain("dev only");
    expect(result.outputFiles[0].text).toContain("x = 1");
  });

  test("pure: 미사용 순수 함수 호출 제거", () => {
    const result = buildSync({
      entryPoints: [join(dir, "pure-test.ts")],
      pure: ["pureUtil"],
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("2");
  });

  test("lineLimit: 줄 길이 제한", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      lineLimit: 40,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });

  test("preserveSymlinks: 옵션 파싱 확인", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      preserveSymlinks: true,
    });
    expect(result.errors.length).toBe(0);
  });

  test("ignoreAnnotations: 옵션 파싱 확인", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      ignoreAnnotations: true,
    });
    expect(result.errors.length).toBe(0);
  });

  test("analyze: metafile 강제 활성화", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      analyze: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.metafile).toBeDefined();
  });

  test("nodePaths: 추가 탐색 경로", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      nodePaths: ["/tmp/nonexistent-path"],
    });
    expect(result.errors.length).toBe(0);
  });

  test("tsconfigRaw: 인라인 tsconfig 오버라이드", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      tsconfigRaw: '{"compilerOptions":{"strict":true}}',
    });
    expect(result.errors.length).toBe(0);
  });

  test("outbase: 엔트리 공통 기준 경로", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      outbase: dir,
    });
    expect(result.errors.length).toBe(0);
  });

  test("sourceRoot: 소스맵 sourceRoot", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      sourcemap: true,
      sourceRoot: "https://example.com/src",
    });
    expect(result.errors.length).toBe(0);
    const mapFile = result.outputFiles.find((f: any) => f.path.endsWith(".map"));
    expect(mapFile).toBeDefined();
    expect(mapFile!.text).toContain("https://example.com/src");
  });
});

// ─── 나머지 BundleOptions 전체 노출 테스트 ───

describe("BundleOptions: 전체 옵션 노출", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-all-opts-"));
    writeFileSync(join(dir, "entry.ts"), "/** @license MIT */\nexport const x = 1;");
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("legalComments: none → 라이센스 주석 제거", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      legalComments: "none",
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain("@license");
  });

  test("legalComments: eof → 파일 끝에 주석 이동", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      legalComments: "eof",
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("@license");
  });

  test("preserveModules: 모듈별 개별 파일 출력", async () => {
    writeFileSync(join(dir, "mod-a.ts"), "export const a = 1;");
    writeFileSync(
      join(dir, "mod-entry.ts"),
      'import { a } from "./mod-a";\nexport const b = a + 1;',
    );
    const result = await build({
      entryPoints: [join(dir, "mod-entry.ts")],
      preserveModules: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThanOrEqual(2);
  });

  test("preserveModulesRoot: 출력 경로 기준", async () => {
    const result = await build({
      entryPoints: [join(dir, "mod-entry.ts")],
      preserveModules: true,
      preserveModulesRoot: dir,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThanOrEqual(2);
  });

  test("timing: 옵션 파싱 확인", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      timing: true,
    });
    expect(result.errors.length).toBe(0);
  });

  test("devMode: dev 모드 활성화", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      devMode: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("__zts_modules");
  });

  test("reactRefresh: Fast Refresh 활성화", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
  });

  test("configurableExports: configurable:true 추가", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      configurableExports: true,
    });
    expect(result.errors.length).toBe(0);
  });

  test("globalIdentifiers: 예약 식별자", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      globalIdentifiers: ["__global", "self"],
    });
    expect(result.errors.length).toBe(0);
  });

  test("rootDir + collectModuleCodes: dev 모드 옵션 조합", () => {
    const result = buildSync({
      entryPoints: [join(dir, "entry.ts")],
      devMode: true,
      rootDir: dir,
      collectModuleCodes: true,
    });
    expect(result.errors.length).toBe(0);
  });
});

// ─── 옵션 조합 + 엣지 케이스 통합 테스트 ───

describe("옵션 조합 통합 테스트", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-combo-"));
    writeFileSync(
      join(dir, "app.ts"),
      'import { util } from "./lib";\nDEV: { console.log("debug"); }\nconsole.log(util());',
    );
    writeFileSync(join(dir, "lib.ts"), "export function util() { return 42; }");
    writeFileSync(join(dir, "logo.txt"), "LOGO_TEXT");
    writeFileSync(
      join(dir, "with-license.ts"),
      '/** @license Apache-2.0 */\nexport const licensed = "yes";',
    );
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("minify + target + dropLabels 조합", () => {
    const result = buildSync({
      entryPoints: [join(dir, "app.ts")],
      minify: true,
      target: "es2020",
      dropLabels: ["DEV"],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain("debug");
    expect(result.outputFiles[0].text).toContain("42");
  });

  test("sourcemap + sourceRoot + outfile 조합", () => {
    const outfile = join(dir, "combo-out", "bundle.js");
    buildSync({
      entryPoints: [join(dir, "app.ts")],
      sourcemap: true,
      sourceRoot: "/src",
      outfile,
      dropLabels: ["DEV"],
    });
    const map = readFileSync(outfile + ".map", "utf-8");
    expect(map).toContain("/src");
    expect(map).toContain("mappings");
    rmSync(join(dir, "combo-out"), { recursive: true, force: true });
  });

  test("loader + packagesExternal 조합", () => {
    writeFileSync(
      join(dir, "asset-entry.ts"),
      'import logo from "./logo.txt";\nimport React from "react";\nexport { logo, React };',
    );
    const result = buildSync({
      entryPoints: [join(dir, "asset-entry.ts")],
      loader: { ".txt": "text" },
      packagesExternal: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("LOGO_TEXT");
    expect(result.outputFiles[0].text).toMatch(/import.*react|require.*react/);
  });

  test("splitting + entryNames + chunkNames 조합", async () => {
    writeFileSync(join(dir, "dyn-entry.ts"), 'export const lazy = () => import("./lib");');
    const result = await build({
      entryPoints: [join(dir, "dyn-entry.ts")],
      splitting: true,
      entryNames: "[name]",
      chunkNames: "chunks/[name]-[hash]",
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThanOrEqual(2);
  });

  test("legalComments: none + minify 조합", () => {
    const result = buildSync({
      entryPoints: [join(dir, "with-license.ts")],
      legalComments: "none",
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain("@license");
  });

  test("format: cjs + platform: node 조합", () => {
    const result = buildSync({
      entryPoints: [join(dir, "lib.ts")],
      format: "cjs",
      platform: "node",
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("use strict");
  });

  test("format: iife + globalName 조합", () => {
    const result = buildSync({
      entryPoints: [join(dir, "lib.ts")],
      format: "iife",
      globalName: "MyLib",
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("MyLib");
  });

  test("define + alias + inject 조합", () => {
    writeFileSync(join(dir, "shim.ts"), "globalThis.__INJECTED__ = true;");
    writeFileSync(
      join(dir, "define-entry.ts"),
      'import { foo } from "@alias/mod";\nconsole.log(__DEV__, foo);',
    );
    writeFileSync(join(dir, "real.ts"), 'export const foo = "real";');
    const result = buildSync({
      entryPoints: [join(dir, "define-entry.ts")],
      define: { __DEV__: "false" },
      alias: { "@alias/mod": join(dir, "real.ts") },
      inject: [join(dir, "shim.ts")],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("false");
    expect(result.outputFiles[0].text).toContain("real");
    expect(result.outputFiles[0].text).toContain("__INJECTED__");
  });

  test("write + outdir + metafile 조합", () => {
    const outdir = join(dir, "meta-out");
    const result = buildSync({
      entryPoints: [join(dir, "lib.ts")],
      outdir,
      metafile: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.metafile).toBeDefined();
    const written = readFileSync(join(outdir, "bundle.js"), "utf-8");
    expect(written.length).toBeGreaterThan(0);
    rmSync(outdir, { recursive: true, force: true });
  });

  test("async build + 모든 플러그인 훅 조합", async () => {
    const hooks: string[] = [];
    const result = await build({
      entryPoints: [join(dir, "app.ts")],
      dropLabels: ["DEV"],
      plugins: [
        vitePlugin({
          name: "full-lifecycle",
          resolveId(source) {
            if (source === "./lib") {
              hooks.push("resolveId");
              return join(dir, "lib.ts");
            }
          },
          load(id) {
            if (id.endsWith("lib.ts")) hooks.push("load");
          },
          transform(code) {
            hooks.push("transform");
          },
          renderChunk(code) {
            hooks.push("renderChunk");
            return `/* built */\n${code}`;
          },
          generateBundle(outputs) {
            hooks.push("generateBundle");
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(hooks).toContain("resolveId");
    expect(hooks).toContain("renderChunk");
    expect(hooks).toContain("generateBundle");
    expect(result.outputFiles[0].text).toContain("/* built */");
  });

  test("allowOverwrite: false → 입력=출력 시 에러", () => {
    expect(() =>
      buildSync({
        entryPoints: [join(dir, "lib.ts")],
        outfile: join(dir, "lib.ts"),
      }),
    ).toThrow("overwrite");
  });

  test("format: umd + globalName → 글로벌 변수로 실행 가능", async () => {
    const result = await build({
      entryPoints: [join(dir, "lib.ts")],
      format: "umd",
      globalName: "MyLib",
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    // 구조 확인
    expect(text).toContain('typeof define === "function"');
    expect(text).toContain("root.MyLib = factory()");
    // 실제 런타임 실행: 글로벌 변수로 접근
    const ctx: Record<string, any> = { self: {} };
    new Function("self", text)(ctx.self);
    expect((ctx.self as any).MyLib).toBeDefined();
    expect((ctx.self as any).MyLib.util()).toBe(42);
  });

  test("format: umd → CJS 모드로 실행 가능", async () => {
    const result = await build({
      entryPoints: [join(dir, "lib.ts")],
      format: "umd",
      globalName: "MyLib",
    });
    // CJS 시뮬레이션: module.exports에 할당
    const mod: any = { exports: {} };
    new Function("module", "exports", result.outputFiles[0].text)(mod, mod.exports);
    expect(mod.exports.util()).toBe(42);
  });

  test("format: amd → define 콜백으로 실행 가능", async () => {
    const result = await build({
      entryPoints: [join(dir, "lib.ts")],
      format: "amd",
    });
    expect(result.errors.length).toBe(0);
    // AMD 시뮬레이션: define(deps, factory) 호출 캡처
    let amdResult: any = null;
    const define: any = (_deps: any, factory: () => any) => {
      amdResult = factory();
    };
    define.amd = true;
    new Function("define", result.outputFiles[0].text)(define);
    expect(amdResult).toBeDefined();
    expect(amdResult.util()).toBe(42);
  });

  test("format: umd (globalName 없음) → factory 직접 실행", async () => {
    const result = await build({
      entryPoints: [join(dir, "lib.ts")],
      format: "umd",
    });
    expect(result.errors.length).toBe(0);
    // globalName 없으면 "else factory()" 경로
    expect(result.outputFiles[0].text).toContain("else factory()");
    // 에러 없이 실행 가능한지 확인
    const ctx: Record<string, any> = { self: {} };
    expect(() => new Function("self", result.outputFiles[0].text)(ctx.self)).not.toThrow();
  });

  test("format: umd + minify → 압축 후 런타임 실행", async () => {
    const result = await build({
      entryPoints: [join(dir, "lib.ts")],
      format: "umd",
      globalName: "M",
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    const mod: any = { exports: {} };
    new Function("module", "exports", result.outputFiles[0].text)(mod, mod.exports);
    expect(mod.exports.util()).toBe(42);
  });

  test("format: amd + minify → 압축 후 런타임 실행", async () => {
    const result = await build({
      entryPoints: [join(dir, "lib.ts")],
      format: "amd",
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    let amdResult: any = null;
    const define: any = (_: any, factory: () => any) => {
      amdResult = factory();
    };
    define.amd = true;
    new Function("define", result.outputFiles[0].text)(define);
    expect(amdResult.util()).toBe(42);
  });

  test("format: umd + 다중 export → 모든 export 접근 가능", async () => {
    writeFileSync(
      join(dir, "multi.ts"),
      "export const a = 1;\nexport const b = 2;\nexport function sum() { return a + b; }",
    );
    const result = await build({
      entryPoints: [join(dir, "multi.ts")],
      format: "umd",
      globalName: "Multi",
    });
    expect(result.errors.length).toBe(0);
    const mod: any = { exports: {} };
    new Function("module", "exports", result.outputFiles[0].text)(mod, mod.exports);
    expect(mod.exports.a).toBe(1);
    expect(mod.exports.b).toBe(2);
    expect(mod.exports.sum()).toBe(3);
  });

  test("format: umd + sourcemap → 소스맵 생성", async () => {
    const result = await build({
      entryPoints: [join(dir, "lib.ts")],
      format: "umd",
      globalName: "Lib",
      sourcemap: true,
    });
    expect(result.errors.length).toBe(0);
    const mapFile = result.outputFiles.find((f: any) => f.path.endsWith(".map"));
    expect(mapFile).toBeDefined();
    expect(mapFile!.text).toContain("mappings");
  });

  test("format: umd + external → 외부 모듈 제외", async () => {
    writeFileSync(join(dir, "ext.ts"), 'import React from "react";\nexport default React;');
    const result = await build({
      entryPoints: [join(dir, "ext.ts")],
      format: "umd",
      globalName: "App",
      external: ["react"],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("require");
  });

  test("format: iife + globalName → 런타임 실행 검증", () => {
    const result = buildSync({
      entryPoints: [join(dir, "lib.ts")],
      format: "iife",
      globalName: "ILib",
    });
    expect(result.errors.length).toBe(0);
    const ctx: any = {};
    new Function("var ILib; " + result.outputFiles[0].text + " return ILib;").call(null);
    // IIFE는 var ILib = (function() { ... })(); 형태
    const fn = new Function(result.outputFiles[0].text + "\nreturn ILib;");
    const lib = fn();
    expect(lib.util()).toBe(42);
  });

  test("format: cjs → use strict + 함수 선언 출력", () => {
    const result = buildSync({
      entryPoints: [join(dir, "lib.ts")],
      format: "cjs",
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('"use strict"');
    expect(result.outputFiles[0].text).toContain("function util()");
  });

  test("allowOverwrite: true → 입력=출력 허용", () => {
    const outfile = join(dir, "overwrite-test.ts");
    writeFileSync(outfile, "export const z = 1;");
    const result = buildSync({
      entryPoints: [outfile],
      outfile,
      allowOverwrite: true,
    });
    expect(result.errors.length).toBe(0);
    rmSync(outfile, { force: true });
  });
});

// ─── 실제 라이브러리 번들링 테스트 ───

describe("실제 라이브러리 번들링", () => {
  let dir: string;
  const projectNodeModules = resolve(__dirname, "../../node_modules");

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-real-lib-"));
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("React: ESM 번들", async () => {
    writeFileSync(
      join(dir, "react-app.tsx"),
      'import React from "react";\nexport const el = React.createElement("div", null, "hello");',
    );
    const result = await build({
      entryPoints: [join(dir, "react-app.tsx")],
      format: "esm",
      jsx: "classic",
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("createElement");
  });

  test("React: UMD + external → require 유지", async () => {
    writeFileSync(
      join(dir, "react-umd.tsx"),
      'import React from "react";\nexport function App() { return React.createElement("div", null, "hi"); }',
    );
    const result = await build({
      entryPoints: [join(dir, "react-umd.tsx")],
      format: "umd",
      globalName: "ReactApp",
      external: ["react"],
      jsx: "classic",
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain("ReactApp");
    expect(text).toContain("require");
  });

  test("React: IIFE 인라인 → 런타임 실행", async () => {
    writeFileSync(
      join(dir, "react-iife.tsx"),
      'import React from "react";\nexport const version = React.version;',
    );
    const result = await build({
      entryPoints: [join(dir, "react-iife.tsx")],
      format: "iife",
      globalName: "ReactBundle",
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    const fn = new Function(result.outputFiles[0].text + "\nreturn ReactBundle;");
    const lib = fn();
    expect(lib.version).toBeDefined();
  });

  test("React + minify → 압축 후 런타임 실행 (#1041)", async () => {
    writeFileSync(
      join(dir, "react-min.tsx"),
      'import React from "react";\nexport const v = React.version;',
    );
    const normal = await build({
      entryPoints: [join(dir, "react-min.tsx")],
      format: "iife",
      globalName: "R",
      nodePaths: [projectNodeModules],
    });
    const minified = await build({
      entryPoints: [join(dir, "react-min.tsx")],
      format: "iife",
      globalName: "R",
      minify: true,
      nodePaths: [projectNodeModules],
    });
    expect(minified.errors.length).toBe(0);
    expect(minified.outputFiles[0].text.length).toBeLessThan(normal.outputFiles[0].text.length);
    // 런타임 실행: minify 후에도 React가 정상 동작
    const fn = new Function(minified.outputFiles[0].text + "\nreturn R;");
    const lib = fn();
    expect(lib.v).toBeDefined();
  });

  test("lodash-es: tree-shaking으로 번들 크기 축소", async () => {
    writeFileSync(
      join(dir, "lodash-app.ts"),
      'import { chunk } from "lodash-es";\nexport const result = chunk([1,2,3,4], 2);',
    );
    const result = await build({
      entryPoints: [join(dir, "lodash-app.ts")],
      format: "esm",
      minify: true,
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text.length).toBeLessThan(50000);
  });

  test("다중 엔트리 + code splitting + React", async () => {
    writeFileSync(
      join(dir, "page-a.tsx"),
      'import React from "react";\nexport const A = React.createElement("div", null, "A");',
    );
    writeFileSync(
      join(dir, "page-b.tsx"),
      'import React from "react";\nexport const B = React.createElement("div", null, "B");',
    );
    const result = await build({
      entryPoints: [join(dir, "page-a.tsx"), join(dir, "page-b.tsx")],
      splitting: true,
      format: "esm",
      jsx: "classic",
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThanOrEqual(3);
  });

  test("React JSX automatic 모드", async () => {
    writeFileSync(join(dir, "jsx-auto.tsx"), "export const App = () => <div>hello</div>;");
    const result = await build({
      entryPoints: [join(dir, "jsx-auto.tsx")],
      jsx: "automatic",
      format: "esm",
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("jsx");
  });

  test("React + define + platform=browser → production 빌드", async () => {
    writeFileSync(
      join(dir, "react-prod.tsx"),
      'import React from "react";\nif (process.env.NODE_ENV !== "production") { console.log("dev"); }\nexport const v = React.version;',
    );
    const result = await build({
      entryPoints: [join(dir, "react-prod.tsx")],
      format: "iife",
      globalName: "Prod",
      platform: "browser",
      define: { "process.env.NODE_ENV": '"production"' },
      minify: true,
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('"dev"');
  });
});

// ─── import.meta.glob 테스트 (#1026) ───

describe("import.meta.glob", () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-glob-"));
    mkdirSync(join(dir, "pages"), { recursive: true });
    writeFileSync(join(dir, "pages", "Home.tsx"), 'export default "Home";');
    writeFileSync(join(dir, "pages", "About.tsx"), 'export default "About";');
    writeFileSync(join(dir, "pages", "Contact.tsx"), 'export default "Contact";');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test("기본 glob: lazy import 객체 생성", () => {
    writeFileSync(
      join(dir, "entry.ts"),
      'const m = import.meta.glob("./pages/*.tsx");\nexport { m };',
    );
    const result = buildSync({ entryPoints: [join(dir, "entry.ts")], format: "esm" });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain("./pages/Home.tsx");
    expect(text).toContain("./pages/About.tsx");
    expect(text).toContain("./pages/Contact.tsx");
    expect(text).toContain("() => import(");
    expect(text).not.toContain("import.meta.glob");
  });

  test("매칭 파일 없는 패턴 → 빈 객체", () => {
    writeFileSync(
      join(dir, "empty.ts"),
      'const m = import.meta.glob("./nonexistent/*.ts");\nexport { m };',
    );
    const result = buildSync({ entryPoints: [join(dir, "empty.ts")], format: "esm" });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain("import(");
  });

  test("다른 확장자 패턴", () => {
    writeFileSync(join(dir, "pages", "data.json"), '{"key":"value"}');
    writeFileSync(
      join(dir, "json-glob.ts"),
      'const m = import.meta.glob("./pages/*.json");\nexport { m };',
    );
    const result = buildSync({ entryPoints: [join(dir, "json-glob.ts")], format: "esm" });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("./pages/data.json");
  });

  test("glob + IIFE 포맷 → 객체 리터럴 출력", () => {
    writeFileSync(
      join(dir, "iife-glob.ts"),
      'const m = import.meta.glob("./pages/*.tsx");\nexport { m };',
    );
    const result = buildSync({
      entryPoints: [join(dir, "iife-glob.ts")],
      format: "iife",
      globalName: "G",
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain("./pages/Home.tsx");
    expect(text).toContain("() => import(");
    expect(text).not.toContain("import.meta.glob");
  });

  test("glob + minify → 축소 후에도 정상 출력", () => {
    writeFileSync(
      join(dir, "min-glob.ts"),
      'const m = import.meta.glob("./pages/*.tsx");\nexport { m };',
    );
    const result = buildSync({
      entryPoints: [join(dir, "min-glob.ts")],
      format: "esm",
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain("./pages/Home.tsx");
    expect(text).toContain("import(");
    expect(text).not.toContain("import.meta.glob");
  });

  test("glob: 코드 내 문자열에 import.meta.glob이 있어도 오탐 안 함", () => {
    writeFileSync(
      join(dir, "no-false-match.ts"),
      'const msg = "use import.meta.glob() to load";\nexport { msg };',
    );
    const result = buildSync({ entryPoints: [join(dir, "no-false-match.ts")], format: "esm" });
    expect(result.errors.length).toBe(0);
    // 문자열 리터럴 안의 import.meta.glob은 교체되지 않아야 함
    expect(result.outputFiles[0].text).toContain("import.meta.glob");
  });
});

// ─── 추가 엣지 케이스 + 조합 테스트 ───

describe("엣지 케이스 + 조합 보강", () => {
  let dir: string;
  const projectNodeModules = resolve(__dirname, "../../node_modules");

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), "zts-edge2-"));
    writeFileSync(join(dir, "simple.ts"), "export const x = () => 1;");
    writeFileSync(
      join(dir, "multi-export.ts"),
      "export const a = 1;\nexport const b = 2;\nexport function add() { return a + b; }",
    );
    writeFileSync(join(dir, "has-console.ts"), 'console.log("hello");\nexport const v = 1;');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  // --- target + format 조합 ---

  test("target: es5 + format: umd → arrow 변환 + UMD 래핑", async () => {
    const result = await build({
      entryPoints: [join(dir, "simple.ts")],
      target: "es5",
      format: "umd",
      globalName: "Lib",
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).not.toContain("=>");
    expect(text).toContain("typeof define");
    expect(text).toContain("factory");
  });

  test("target: es5 + format: amd → arrow 변환 + AMD 래핑", async () => {
    const result = await build({
      entryPoints: [join(dir, "simple.ts")],
      target: "es5",
      format: "amd",
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain("=>");
    expect(result.outputFiles[0].text).toContain("define([]");
  });

  // --- dropLabels + minify ---

  test("dropLabels + minify: 라벨 제거 후 압축", () => {
    writeFileSync(join(dir, "label-min.ts"), 'DEV: { console.log("dev"); }\nexport const x = 1;');
    const result = buildSync({
      entryPoints: [join(dir, "label-min.ts")],
      dropLabels: ["DEV"],
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain("dev");
  });

  // --- 다중 포맷 런타임 검증 ---

  test("format: esm → export 구문 유지", () => {
    const result = buildSync({
      entryPoints: [join(dir, "multi-export.ts")],
      format: "esm",
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("export");
  });

  test("format: cjs + minify", () => {
    const result = buildSync({
      entryPoints: [join(dir, "simple.ts")],
      format: "cjs",
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('"use strict"');
  });

  // --- sourcemap 조합 ---

  test("sourcemap + minify + target: es5", () => {
    const result = buildSync({
      entryPoints: [join(dir, "simple.ts")],
      sourcemap: true,
      minify: true,
      target: "es5",
    });
    expect(result.errors.length).toBe(0);
    const mapFile = result.outputFiles.find((f: any) => f.path.endsWith(".map"));
    expect(mapFile).toBeDefined();
    expect(mapFile!.text).toContain("mappings");
  });

  // --- 플러그인 + 옵션 조합 ---

  test("플러그인 onTransform + target", async () => {
    const result = await build({
      entryPoints: [join(dir, "has-console.ts")],
      target: "es2020",
      plugins: [
        vitePlugin({
          name: "replacer",
          transform(code) {
            return code.replace("hello", "TRANSFORMED");
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("TRANSFORMED");
  });

  test("플러그인 renderChunk + format: umd", async () => {
    const result = await build({
      entryPoints: [join(dir, "simple.ts")],
      format: "umd",
      globalName: "T",
      plugins: [
        vitePlugin({
          name: "chunk-stamp",
          renderChunk(code) {
            return `/* stamped */\n${code}`;
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("/* stamped */");
    expect(result.outputFiles[0].text).toContain("typeof define");
  });

  // --- 빈 입력 / 에러 ---

  test("존재하지 않는 파일 → 에러", () => {
    const result = buildSync({ entryPoints: [join(dir, "nonexistent.ts")] });
    expect(result.errors.length).toBeGreaterThan(0);
  });

  test("빈 파일 → 정상 빌드", () => {
    writeFileSync(join(dir, "empty.ts"), "");
    const result = buildSync({ entryPoints: [join(dir, "empty.ts")] });
    expect(result.errors.length).toBe(0);
  });

  // --- write + 다양한 포맷 ---

  test("write + outdir + format: umd", () => {
    const outdir = join(dir, "umd-out");
    const result = buildSync({
      entryPoints: [join(dir, "simple.ts")],
      format: "umd",
      globalName: "W",
      outdir,
    });
    expect(result.errors.length).toBe(0);
    const written = readFileSync(join(outdir, "bundle.js"), "utf-8");
    expect(written).toContain("typeof define");
    rmSync(outdir, { recursive: true, force: true });
  });

  // --- React + 다양한 포맷 ---

  test("React: AMD + external → define 래핑", async () => {
    writeFileSync(
      join(dir, "react-amd.tsx"),
      'import React from "react";\nexport const el = React.createElement("div");',
    );
    const result = await build({
      entryPoints: [join(dir, "react-amd.tsx")],
      format: "amd",
      external: ["react"],
      jsx: "classic",
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain("define([]");
    expect(result.outputFiles[0].text).toContain("require");
  });

  // --- minifyIdentifiers + for-in (NAPI 레벨 검증) ---

  test("minifyIdentifiers: for-in LHS 변수가 올바르게 리네이밍됨", () => {
    writeFileSync(
      join(dir, "forin.js"),
      "var myObj = { a: 1 };\nvar myKey;\nfor (myKey in myObj) { console.log(myKey); }\nexport var result = myKey;",
    );
    const result = buildSync({
      entryPoints: [join(dir, "forin.js")],
      format: "esm",
      minifyIdentifiers: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain("myKey");
    expect(result.outputFiles[0].text).not.toContain("myObj");
  });

  test("minifyIdentifiers: 함수 내부 var hoisting", () => {
    writeFileSync(
      join(dir, "hoist.js"),
      "export default (function() { console.log(longName); var longName = 42; return longName; })();",
    );
    const result = buildSync({
      entryPoints: [join(dir, "hoist.js")],
      format: "esm",
      minifyIdentifiers: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain("longName");
  });
});
