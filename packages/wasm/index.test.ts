import { describe, test, expect, beforeAll } from "bun:test";
import { readFileSync } from "fs";
import { join } from "path";
import {
  initSync,
  transpile,
  VirtualFileSystem,
  initBundler,
  bundlerVersion,
  build,
  buildChunks,
  bundlerLastErrorMessage,
} from "./index";

beforeAll(() => {
  const wasmPath = join(import.meta.dir, "../../zig-out/bin/zts.wasm");
  const wasmBytes = readFileSync(wasmPath);
  initSync(wasmBytes);
});

describe("@zts/wasm", () => {
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
    // 공백이 축소되어야 함
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

  test("빈 출력도 정상 반환 — TS 타입 전용 파일", () => {
    // `type Foo`/`declare`만 있으면 스트리핑 후 출력이 0바이트.
    // Zig 빈 slice의 `.ptr`이 sentinel이라 u64 packing + BigInt sign-extension 탓에
    // JS에서 outPtr=-1로 나타나 RangeError가 발생하던 회귀 방지.
    expect(transpile("type Foo = string;").code).toBe("");
    expect(transpile("declare const x: number;").code).toBe("");
    expect(transpile('import { foo } from "./bar";', { filename: "a.ts" }).code).toBe("");
    // whitespace/comment-only 도 내용상 코드가 없음 → 빈 출력.
    expect(transpile("   \n\t").code).toBe("");
    expect(transpile("/* just a block comment */").code).toContain("/* just a block comment */");
  });

  test("파싱 에러", () => {
    // miette 스타일 렌더: "× <message> [ZTS코드]"
    expect(() => transpile("const = ;")).toThrow(/\[ZTS\d{4}\]/);
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

  test("initSync 중복 호출은 무시", () => {
    // 이미 초기화됨 — 에러 없이 무시되어야 함
    expect(() => initSync(new ArrayBuffer(0))).not.toThrow();
  });

  test("여러 번 호출해도 메모리 누수 없이 동작", () => {
    for (let i = 0; i < 100; i++) {
      const result = transpile(`const x${i}: number = ${i};`);
      expect(result.code).toContain(`const x${i} = ${i};`);
    }
  });
});

// VirtualFileSystem (#1885 Phase 2 PR 6-2b) — bundler 의 host fs 추상화.
// 단위 테스트는 pure JS (wasm 무관). bundler instance + zts_fs callback 통합은 PR 6-2c.
describe("VirtualFileSystem", () => {
  test("set / get string content (utf-8 encoded)", () => {
    const vfs = new VirtualFileSystem();
    vfs.set("/index.ts", "export const x = 1;");
    const data = vfs.get("/index.ts");
    expect(data).toBeDefined();
    expect(new TextDecoder().decode(data!)).toBe("export const x = 1;");
  });

  test("set / get Uint8Array content (binary 보존)", () => {
    const vfs = new VirtualFileSystem();
    const bytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47]); // PNG header
    vfs.set("/image.png", bytes);
    expect(vfs.get("/image.png")).toEqual(bytes);
  });

  test("has / delete / clear", () => {
    const vfs = new VirtualFileSystem();
    vfs.set("/a", "1");
    vfs.set("/b", "2");
    expect(vfs.has("/a")).toBe(true);
    expect(vfs.has("/c")).toBe(false);
    expect(vfs.size()).toBe(2);

    expect(vfs.delete("/a")).toBe(true);
    expect(vfs.delete("/a")).toBe(false);
    expect(vfs.size()).toBe(1);

    vfs.clear();
    expect(vfs.size()).toBe(0);
  });

  test("paths iterator", () => {
    const vfs = new VirtualFileSystem();
    vfs.set("/a.ts", "");
    vfs.set("/b.ts", "");
    vfs.set("/c.ts", "");
    const collected = [...vfs.paths()].sort();
    expect(collected).toEqual(["/a.ts", "/b.ts", "/c.ts"]);
  });

  test("재set 시 덮어쓰기", () => {
    const vfs = new VirtualFileSystem();
    vfs.set("/x", "first");
    vfs.set("/x", "second");
    expect(new TextDecoder().decode(vfs.get("/x")!)).toBe("second");
    expect(vfs.size()).toBe(1);
  });
});

// PR 6-2c-2c — bundler.Bundler.init + bundle() 실 호출 + VFS round-trip.
// esm/browser 단일 entry. 출력은 단일 파일 모드 (result.output) — 모듈 wrap + TS strip.
describe("Bundler (minimal)", () => {
  beforeAll(async () => {
    const wasmPath = join(import.meta.dir, "../../zig-out/bin/zts-bundler.wasm");
    const wasmBytes = readFileSync(wasmPath);
    const vfs = new VirtualFileSystem();
    vfs.set("/index.ts", "export const x = 42;");
    vfs.set("/utils.ts", "export const greet = (n: string) => `hi ${n}`;");
    await initBundler(vfs, wasmBytes);
  });

  test("bundlerVersion = ABI v5 (transpile 옵션 노출)", () => {
    expect(bundlerVersion()).toBe(5);
  });

  test("build: 단일 entry → bundle 코드 (TS 어노테이션 strip + 모듈 wrap)", () => {
    const result = build("/index.ts");
    expect(result).not.toBeNull();
    // 번들러는 entry 모듈을 wrap 해서 single bundle 로 emit.
    // 정확한 wrap 형식은 bundler 구현에 종속 — 핵심 시맨틱만 검증.
    expect(result?.code).toContain("const x = 42;");
    expect(result?.code).toContain("export { x }");
  });

  test("build: TS 어노테이션 (`: string`) 이 strip 됨", () => {
    const result = build("/utils.ts");
    expect(result).not.toBeNull();
    expect(result?.code).not.toContain(": string");
    expect(result?.code).toContain("greet");
    expect(result?.code).toContain("`hi ${n}`");
  });

  test("build: 존재하지 않는 entry → null", () => {
    const result = build("/nonexistent.ts");
    expect(result).toBeNull();
  });

  test("build: format=cjs 옵션 → CJS prologue (`use strict`) 추가", () => {
    const esmOut = build("/index.ts", { format: "esm" });
    const cjsOut = build("/index.ts", { format: "cjs" });
    expect(cjsOut).not.toBeNull();
    // CJS 모드는 `"use strict"` prologue 를 자동 추가 (esm 은 미추가).
    expect(cjsOut?.code).toContain('"use strict"');
    expect(esmOut?.code).not.toContain('"use strict"');
  });

  test("build: minifyWhitespace 옵션 → 공백 압축", () => {
    const baseline = build("/utils.ts");
    const minified = build("/utils.ts", { minifyWhitespace: true });
    expect(baseline).not.toBeNull();
    expect(minified).not.toBeNull();
    // 압축 시 baseline 보다 작거나 같음 (보통 작음).
    expect(minified!.code.length).toBeLessThan(baseline!.code.length);
  });

  test("build: minify shorthand → whitespace + identifiers + syntax 모두 활성", () => {
    const baseline = build("/utils.ts");
    const minified = build("/utils.ts", { minify: true });
    expect(minified).not.toBeNull();
    expect(minified!.code.length).toBeLessThan(baseline!.code.length);
  });

  test("build: 잘못된 옵션 값 (unknown format) → 무시 + 기본값 사용", () => {
    // Zig 측 parseFormat 가 unknown 이면 default (.esm) 유지.
    const result = build("/index.ts", { format: "made-up" as any });
    expect(result).not.toBeNull();
    expect(result?.code).toContain("export { x }");
  });

  test("build: 미지원 옵션 필드 → ignore (forward compat)", () => {
    // ignore_unknown_fields=true 이라 신규 필드는 silent skip.
    const result = build("/index.ts", { someFutureOption: 42 } as any);
    expect(result).not.toBeNull();
  });

  test("buildChunks: 단일 entry → 한 개 chunk wrap", () => {
    const chunks = buildChunks("/index.ts");
    expect(chunks).not.toBeNull();
    expect(chunks!.length).toBe(1);
    expect(chunks![0].path).toBe("bundle.js");
    expect(chunks![0].code).toContain("const x = 42;");
  });

  test("buildChunks: 옵션 (format=cjs) 적용", () => {
    const chunks = buildChunks("/index.ts", { format: "cjs" });
    expect(chunks).not.toBeNull();
    expect(chunks!.length).toBe(1);
    expect(chunks![0].code).toContain('"use strict"');
  });

  test("buildChunks: 존재하지 않는 entry → null + 에러 메시지", () => {
    const chunks = buildChunks("/nonexistent.ts");
    expect(chunks).toBeNull();
    const msg = bundlerLastErrorMessage();
    expect(msg.length).toBeGreaterThan(0);
    // bundle 단계 실패 또는 빈 출력 — 둘 중 하나로 분류되며 메시지에 표시.
    expect(msg).toMatch(/bundle|nonexistent|빈 출력/);
  });

  test("bundlerLastErrorMessage: 성공 호출 후엔 비어있음", () => {
    buildChunks("/index.ts"); // 성공
    expect(bundlerLastErrorMessage()).toBe("");
  });

  test("buildChunks: JSON escape — code 안의 특수 문자 round-trip", () => {
    // 출력에 quote / newline / backslash 가 들어가니 JSON escape 검증.
    const chunks = buildChunks("/utils.ts");
    expect(chunks).not.toBeNull();
    // utils.ts 의 template literal `hi ${n}` 가 그대로 출력에 — backtick / dollar / brace
    expect(chunks![0].code).toContain("`hi ${n}`");
    // newline 도 escape 안 깨지고 round-trip
    expect(chunks![0].code.split("\n").length).toBeGreaterThan(1);
  });

  test("build: target=es5 옵션 → 화살표 함수가 function 으로 다운레벨링", () => {
    // utils.ts 의 `(n) => ...` arrow 가 baseline (esnext) 에는 그대로,
    // es5 에선 function expression 으로 변환되어야 함.
    const baseline = build("/utils.ts");
    const downleveled = build("/utils.ts", { target: "es5" });
    expect(baseline).not.toBeNull();
    expect(downleveled).not.toBeNull();
    expect(baseline?.code).toContain("=>");
    expect(downleveled?.code).not.toContain("=>");
    expect(downleveled?.code).toContain("function");
  });

  test("build: jsxFactory 커스텀 옵션 적용", () => {
    // 임시로 JSX 파일 추가 — 그러나 globalVfs 가 모듈-수준이라 직접 set 안 됨.
    // utils.ts 에 JSX 가 없으니 jsx 옵션 효과 없음. 그래서 ABI smoke test 만 — 옵션
    // 전달이 에러 없이 처리되는지 확인.
    const result = build("/index.ts", {
      jsx: "classic",
      jsxFactory: "h",
      jsxFragment: "Frag",
    });
    expect(result).not.toBeNull();
  });
});
