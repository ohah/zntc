import { describe, test, expect } from "bun:test";
import { runZts, runZtsInDir, createFixture } from "./helpers";
import { join, resolve } from "node:path";

const FIXTURES = resolve(import.meta.dir, "fixtures/ast-info-preservation");

/**
 * AST 정보 보존 contract:
 * 1. import attributes (with/assert): 키·값 모두 출력에 보존
 * 2. import defer/source phase modifier: 출력에 보존
 * 3. TS type parameter modifier (const/in/out): TS strip 후 trailing JS에는 안 나타나지만
 *    AST에는 보존 (modifier 정보 손실 X)
 *
 * 출처:
 * - babel-flow/test/fixtures/es2025/import-attributes/
 * - babel-flow/test/fixtures/experimental/deferred-import-evaluation/import-defer/
 * - babel-flow/test/fixtures/typescript/types/const-type-parameters/
 */

describe("import attributes (with/assert) AST 보존", () => {
  test("기본 with { type: 'json' } 보존", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.mjs": `import data from "./data.json" with { type: "json" };\nconsole.log(data);`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.mjs"]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('with {type: "json"}');
    } finally {
      await cleanup();
    }
  });

  test("다중 attribute 보존 (key1, key2)", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.mjs": `import x from "./y" with { type: "json", lazy: "true" };\nconsole.log(x);`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.mjs"]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('"json"');
      expect(stdout).toContain('"true"');
      // 키 보존
      expect(stdout).toContain("type:");
      expect(stdout).toContain("lazy:");
    } finally {
      await cleanup();
    }
  });

  test("string literal 키 보존", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.mjs": `import x from "./y" with { "for": "for" };\nconsole.log(x);`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.mjs"]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('"for"');
    } finally {
      await cleanup();
    }
  });

  test("trailing comma 허용", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.mjs": `import x from "./y" with { type: "json", };\nconsole.log(x);`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.mjs"]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('with {type: "json"}');
    } finally {
      await cleanup();
    }
  });

  test("빈 attributes (with {})", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.mjs": `import x from "./y" with {};\nconsole.log(x);`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.mjs"]);
      expect(exitCode).toBe(0);
      // 빈 with는 의미 없으므로 생략 가능 — 우리는 이 경우 with {}를 출력하지 않거나 그대로 출력.
      // contract: 적어도 import는 살아있고 컴파일 에러 없음
      expect(stdout).toContain("import");
      expect(stdout).toContain("./y");
    } finally {
      await cleanup();
    }
  });

  test("named import + attributes", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.mjs": `import { a, b } from "./y" with { type: "json" };\nconsole.log(a, b);`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.mjs"]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('with {type: "json"}');
    } finally {
      await cleanup();
    }
  });

  test("namespace import + attributes", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.mjs": `import * as ns from "./y" with { type: "json" };\nconsole.log(ns);`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.mjs"]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('with {type: "json"}');
    } finally {
      await cleanup();
    }
  });

  test("side-effect import + attributes", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.mjs": `import "./y.css" with { type: "css" };`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.mjs"]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain('with {type: "css"}');
    } finally {
      await cleanup();
    }
  });

  test("legacy assert 키워드도 동작", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.mjs": `import x from "./y.json" assert { type: "json" };\nconsole.log(x);`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.mjs"]);
      expect(exitCode).toBe(0);
      // assert도 with와 동일하게 emit (또는 그대로 보존) — 적어도 type:json은 출력
      expect(stdout).toContain('"json"');
    } finally {
      await cleanup();
    }
  });

  test("중복 키는 에러 (with { type: 'json', type: 'webpack' })", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.mjs": `import x from "./y" with { type: "json", type: "webpack" };`,
    });
    try {
      const { stderr } = await runZtsInDir(dir, ["entry.mjs"]);
      expect(stderr).toMatch(/Duplicate import attribute|duplicate/i);
    } finally {
      await cleanup();
    }
  });

  test("Babel fixture (string-literal): 파싱 통과", async () => {
    // 출력은 unused import strip으로 import가 사라질 수 있으나 SyntaxError 없으면 OK
    const { exitCode } = await runZts([join(FIXTURES, "import-attributes/string-literal.mjs")]);
    expect(exitCode).toBe(0);
  });

  test("Babel fixture (trailing-comma): 파싱 통과", async () => {
    const { exitCode } = await runZts([join(FIXTURES, "import-attributes/trailing-comma.mjs")]);
    expect(exitCode).toBe(0);
  });
});

describe("import defer/source (Stage 3) AST 보존", () => {
  test("import defer * as", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.mjs": `import defer * as ns from "./d";\nconsole.log(ns);`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.mjs"]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain("import defer * as ns");
    } finally {
      await cleanup();
    }
  });

  test("import source * as", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.mjs": `import source * as s from "./s";\nconsole.log(s);`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.mjs"]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain("import source * as s");
    } finally {
      await cleanup();
    }
  });

  test('`import defer from "x"` 는 default import (defer가 binding name)', async () => {
    const { dir, cleanup } = await createFixture({
      "entry.mjs": `import defer from "./d";\nconsole.log(defer);`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.mjs"]);
      expect(exitCode).toBe(0);
      // defer는 binding으로 출력
      expect(stdout).toContain("import defer from");
    } finally {
      await cleanup();
    }
  });

  test("Babel fixture (basic.mjs): 파싱 통과", async () => {
    const { exitCode } = await runZts([join(FIXTURES, "import-defer/basic.mjs")]);
    expect(exitCode).toBe(0);
  });

  test("phase modifier + attributes 동시", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.mjs": `import defer * as ns from "./d" with { type: "json" };\nconsole.log(ns);`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.mjs"]);
      expect(exitCode).toBe(0);
      expect(stdout).toContain("import defer");
      expect(stdout).toContain('with {type: "json"}');
    } finally {
      await cleanup();
    }
  });
});

describe("TS type parameter modifier (const/in/out) AST 보존", () => {
  // TS strip 후 출력엔 generic 자체가 사라지므로 modifier 검증은
  // "파싱이 에러 없이 통과"로 한정 (AST 내부 보존은 Zig 유닛 테스트에서)
  test("function<const T>", async () => {
    const { dir, cleanup } = await createFixture({
      "f.ts": `function a<const T>(x: T): T { return x; }\nconsole.log(a(1));`,
    });
    try {
      const { exitCode } = await runZtsInDir(dir, ["f.ts"]);
      expect(exitCode).toBe(0);
    } finally {
      await cleanup();
    }
  });

  test("class<in T> + class<out T> + class<in out T>", async () => {
    const { dir, cleanup } = await createFixture({
      "f.ts": `class A<in T> { x?: T }\nclass B<out T> { y?: T }\nclass C<in out T> { z?: T }\nnew A(); new B(); new C();`,
    });
    try {
      const { exitCode } = await runZtsInDir(dir, ["f.ts"]);
      expect(exitCode).toBe(0);
    } finally {
      await cleanup();
    }
  });

  test("class<const in T> 다중 modifier", async () => {
    const { dir, cleanup } = await createFixture({
      "f.ts": `class D<const in T> { x?: T }\nnew D();`,
    });
    try {
      const { exitCode } = await runZtsInDir(dir, ["f.ts"]);
      expect(exitCode).toBe(0);
    } finally {
      await cleanup();
    }
  });

  test("interface<const T extends U>", async () => {
    const { dir, cleanup } = await createFixture({
      "f.ts": `type U = string;\ninterface I<const T extends U> { value: T }\nconst v: I<"x"> = { value: "x" };\nconsole.log(v);`,
    });
    try {
      const { exitCode } = await runZtsInDir(dir, ["f.ts"]);
      expect(exitCode).toBe(0);
    } finally {
      await cleanup();
    }
  });

  test("Babel const-type-parameters fixture (모든 형태)", async () => {
    const { exitCode } = await runZts([join(FIXTURES, "ts-type-param-modifier/const-modifier.ts")]);
    expect(exitCode).toBe(0);
  });

  test("`<in out>`에서 out은 modifier 아닌 이름", async () => {
    // <in out>: in은 modifier, out은 type parameter 이름
    const { dir, cleanup } = await createFixture({
      "f.ts": `class X<in out> { y?: out }\nnew X();`,
    });
    try {
      const { exitCode } = await runZtsInDir(dir, ["f.ts"]);
      expect(exitCode).toBe(0);
    } finally {
      await cleanup();
    }
  });
});

describe("E2E: Node로 import attributes 실행", () => {
  test("ESM import with attributes — Node SyntaxError 없이 파싱", async () => {
    const { dir, cleanup } = await createFixture({
      "data.json": `{"hello": "world"}`,
      "entry.mjs": `import data from "./data.json" with { type: "json" };\nconsole.log(JSON.stringify(data));`,
    });
    try {
      const { stdout, exitCode } = await runZtsInDir(dir, ["entry.mjs"]);
      expect(exitCode).toBe(0);
      // 출력된 JS를 별도 .mjs로 저장 후 Node 실행
      const out = stdout;
      const { writeFile } = await import("node:fs/promises");
      const { spawn } = await import("node:child_process");
      await writeFile(join(dir, "out.mjs"), out);
      const run = spawn("node", [join(dir, "out.mjs")], { stdio: ["ignore", "pipe", "pipe"] });
      const data: string[] = [];
      run.stdout.on("data", (b: Buffer) => data.push(b.toString()));
      const ec: number = await new Promise((res) => run.on("exit", (c) => res(c ?? 1)));
      expect(ec).toBe(0);
      expect(data.join("")).toContain('"hello":"world"');
    } finally {
      await cleanup();
    }
  });
});
