/**
 * @zts/core NAPI 바인딩 Node.js 테스트
 *
 * Node.js에서 .node addon이 정상 로드되고 동작하는지 검증.
 * 실행: node --test packages/core/napi.test.mjs
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

// .node 파일 직접 로드
const addonPath = join(__dirname, "../../zig-out/lib/zts.node");
const native = require(addonPath);

describe("@zts/core NAPI (Node.js)", () => {
  it("모듈이 transpile 함수를 export한다", () => {
    assert.equal(typeof native.transpile, "function");
  });

  it("기본 TypeScript 트랜스파일", () => {
    const flags = (1 << 16) | (1 << 22); // useDefineForClassFields + sourcesContent
    const result = native.transpile("const x: number = 1;", "input.ts", flags, 0, "", "", "");
    assert.ok(result.code.includes("const x = 1;"));
    assert.equal(result.map, undefined);
  });

  it("인터페이스 스트리핑", () => {
    const flags = (1 << 16) | (1 << 22);
    const result = native.transpile(
      "interface Foo { bar: string; }\nconst x = 1;",
      "input.ts",
      flags,
      0,
      "",
      "",
      "",
    );
    assert.ok(!result.code.includes("interface"));
    assert.ok(result.code.includes("const x = 1;"));
  });

  it("타입 어노테이션 제거", () => {
    const flags = (1 << 16) | (1 << 22);
    const result = native.transpile(
      "function add(a: number, b: number): number { return a + b; }",
      "input.ts",
      flags,
      0,
      "",
      "",
      "",
    );
    assert.ok(!result.code.includes(": number"));
  });

  it("소스맵 생성", () => {
    const flags = (1 << 0) | (1 << 16) | (1 << 22); // sourcemap + defaults
    const result = native.transpile("const x: number = 1;", "input.ts", flags, 0, "", "", "");
    assert.ok(result.code.includes("const x = 1;"));
    assert.ok(result.map !== undefined);
    const map = JSON.parse(result.map);
    assert.equal(map.version, 3);
    assert.ok(map.mappings);
  });

  it("CJS 포맷", () => {
    const flags = (1 << 12) | (1 << 16) | (1 << 22); // cjs + defaults
    const result = native.transpile(
      'export const x = 1; export default "hello";',
      "input.ts",
      flags,
      0,
      "",
      "",
      "",
    );
    assert.ok(result.code.includes("exports"));
  });

  it("JSX 트랜스파일 (classic)", () => {
    const flags = (1 << 16) | (1 << 22);
    const result = native.transpile(
      '<div className="app">hello</div>',
      "app.tsx",
      flags,
      0,
      "",
      "",
      "",
    );
    assert.ok(result.code.includes("React.createElement"));
  });

  it("JSX 트랜스파일 (automatic)", () => {
    const flags = (1 << 4) | (1 << 16) | (1 << 22); // automatic jsx
    const result = native.transpile(
      '<div className="app">hello</div>',
      "app.tsx",
      flags,
      0,
      "",
      "",
      "",
    );
    assert.ok(result.code.includes("jsx"));
  });

  it("jsxFactory 커스텀", () => {
    const flags = (1 << 16) | (1 << 22);
    const result = native.transpile("<div />", "app.tsx", flags, 0, "h", "", "");
    assert.ok(result.code.includes("h("));
    assert.ok(!result.code.includes("React.createElement"));
  });

  it("jsxImportSource 커스텀", () => {
    const flags = (1 << 4) | (1 << 16) | (1 << 22); // automatic jsx
    const result = native.transpile("<div />", "app.tsx", flags, 0, "", "", "preact");
    assert.ok(result.code.includes("preact"));
  });

  it("ES5 다운레벨링", () => {
    const flags = (1 << 16) | (1 << 22);
    const unsupported = 0x1fffff; // es5
    const result = native.transpile(
      "const x = () => 1;",
      "input.ts",
      flags,
      unsupported,
      "",
      "",
      "",
    );
    assert.ok(!result.code.includes("=>"));
    assert.ok(result.code.includes("function"));
  });

  it("drop console", () => {
    const flags = (1 << 6) | (1 << 16) | (1 << 22); // drop_console + defaults
    const result = native.transpile(
      'console.log("hello"); const x = 1;',
      "input.ts",
      flags,
      0,
      "",
      "",
      "",
    );
    assert.ok(!result.code.includes("console.log"));
    assert.ok(result.code.includes("const x = 1;"));
  });

  it("파싱 에러 시 throw", () => {
    const flags = (1 << 16) | (1 << 22);
    assert.throws(
      () => native.transpile("const = ;", "input.ts", flags, 0, "", "", ""),
      (err) => err.message.includes("ParseError"),
    );
  });

  it("반복 호출 안정성", () => {
    const flags = (1 << 16) | (1 << 22);
    for (let i = 0; i < 100; i++) {
      const result = native.transpile(
        `const x${i}: number = ${i};`,
        "input.ts",
        flags,
        0,
        "",
        "",
        "",
      );
      assert.ok(result.code.includes(`const x${i} = ${i};`));
    }
  });
});
