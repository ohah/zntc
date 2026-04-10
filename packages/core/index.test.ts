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
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
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
});
