import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { init, transpile, close } from "./index";

beforeAll(() => {
  init();
});

afterAll(() => {
  close();
});

describe("@zts/ffi", () => {
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
