/**
 * @zts/core NAPI 바인딩 Node.js 테스트
 *
 * Node.js에서 .node addon이 정상 로드되고 동작하는지 검증.
 * 실행: node --test packages/core/napi.test.mjs
 */

import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

// .node 파일 직접 로드
const addonPath = join(__dirname, "../../zig-out/lib/zts.node");
const native = require(addonPath);

// 옵션은 단일 JSON payload (camelCase, Zig TranspileOptionsDto와 매핑).
// 기본값(useDefineForClassFields, sourcesContent 등)은 Zig 측에서 처리하므로 생략 가능.
const call = (src, filename, opts = {}) => native.transpile(src, filename, JSON.stringify(opts));

describe("@zts/core NAPI (Node.js)", () => {
  it("모듈이 transpile 함수를 export한다", () => {
    assert.equal(typeof native.transpile, "function");
  });

  it("기본 TypeScript 트랜스파일", () => {
    const result = call("const x: number = 1;", "input.ts");
    assert.ok(result.code.includes("const x = 1;"));
    assert.equal(result.map, undefined);
  });

  it("인터페이스 스트리핑", () => {
    const result = call("interface Foo { bar: string; }\nconst x = 1;", "input.ts");
    assert.ok(!result.code.includes("interface"));
    assert.ok(result.code.includes("const x = 1;"));
  });

  it("타입 어노테이션 제거", () => {
    const result = call("function add(a: number, b: number): number { return a + b; }", "input.ts");
    assert.ok(!result.code.includes(": number"));
  });

  it("소스맵 생성", () => {
    const result = call("const x: number = 1;", "input.ts", { sourcemap: true });
    assert.ok(result.code.includes("const x = 1;"));
    assert.ok(result.map !== undefined);
    const map = JSON.parse(result.map);
    assert.equal(map.version, 3);
    assert.ok(map.mappings);
  });

  it("CJS 포맷", () => {
    const result = call('export const x = 1; export default "hello";', "input.ts", {
      format: "cjs",
    });
    assert.ok(result.code.includes("exports"));
  });

  it("JSX 트랜스파일 (classic)", () => {
    const result = call('<div className="app">hello</div>', "app.tsx");
    assert.ok(result.code.includes("React.createElement"));
  });

  it("JSX 트랜스파일 (automatic)", () => {
    const result = call('<div className="app">hello</div>', "app.tsx", { jsx: "automatic" });
    assert.ok(result.code.includes("jsx"));
  });

  it("jsxFactory 커스텀", () => {
    const result = call("<div />", "app.tsx", { jsxFactory: "h" });
    assert.ok(result.code.includes("h("));
    assert.ok(!result.code.includes("React.createElement"));
  });

  it("jsxImportSource 커스텀", () => {
    const result = call("<div />", "app.tsx", { jsx: "automatic", jsxImportSource: "preact" });
    assert.ok(result.code.includes("preact"));
  });

  it("ES5 다운레벨링", () => {
    const result = call("const x = () => 1;", "input.ts", { target: "es5" });
    assert.ok(!result.code.includes("=>"));
    assert.ok(result.code.includes("function"));
  });

  it("drop console", () => {
    const result = call('console.log("hello"); const x = 1;', "input.ts", { dropConsole: true });
    assert.ok(!result.code.includes("console.log"));
    assert.ok(result.code.includes("const x = 1;"));
  });

  it("파싱 에러 시 throw", () => {
    assert.throws(
      () => call("const = ;", "input.ts"),
      (err) => err.message.includes("ParseError"),
    );
  });

  it("반복 호출 안정성", () => {
    for (let i = 0; i < 100; i++) {
      const result = call(`const x${i}: number = ${i};`, "input.ts");
      assert.ok(result.code.includes(`const x${i} = ${i};`));
    }
  });
});

import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";

describe("@zts/core buildSync NAPI (Node.js)", () => {
  const dir = mkdtempSync(join(tmpdir(), "zts-napi-build-"));
  writeFileSync(
    join(dir, "entry.ts"),
    'import { hello } from "./util";\nconsole.log(hello("world"));',
  );
  writeFileSync(
    join(dir, "util.ts"),
    "export function hello(name: string): string { return `Hello, ${name}!`; }",
  );

  after(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("기본 번들링", () => {
    const result = native.buildSync({
      entryPoints: [join(dir, "entry.ts")],
    });
    assert.ok(result.outputFiles.length > 0);
    assert.equal(result.errors.length, 0);
    assert.ok(result.outputFiles[0].text.includes("hello"));
  });

  it("소스맵 생성", () => {
    const result = native.buildSync({
      entryPoints: [join(dir, "entry.ts")],
      sourcemap: true,
    });
    assert.equal(result.outputFiles.length, 2);
    const smFile = result.outputFiles.find((f) => f.path.endsWith(".map"));
    assert.ok(smFile);
    const map = JSON.parse(smFile.text);
    assert.equal(map.version, 3);
  });

  it("minify", () => {
    const normal = native.buildSync({ entryPoints: [join(dir, "entry.ts")] });
    const minified = native.buildSync({
      entryPoints: [join(dir, "entry.ts")],
      minify: true,
    });
    assert.ok(minified.outputFiles[0].text.length < normal.outputFiles[0].text.length);
  });

  it("metafile", () => {
    const result = native.buildSync({
      entryPoints: [join(dir, "entry.ts")],
      metafile: true,
    });
    assert.ok(result.metafile);
    const meta = JSON.parse(result.metafile);
    assert.ok(meta.outputs);
  });
});
