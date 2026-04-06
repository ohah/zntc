import { describe, test, expect, afterEach } from "bun:test";
import { createFixture, runZts } from "./helpers";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

describe("소스맵", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("번들 소스맵에 sourcesContent가 포함된다", async () => {
    const fixture = await createFixture({
      "index.ts": `import { add } from "./math";\nconsole.log(add(1, 2));`,
      "math.ts": `export function add(a: number, b: number): number {\n  return a + b;\n}`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const result = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--sourcemap",
    ]);
    expect(result.exitCode).toBe(0);

    // .map 파일이 생성되어야 한다
    const mapPath = outFile + ".map";
    expect(existsSync(mapPath)).toBe(true);

    const map = JSON.parse(readFileSync(mapPath, "utf-8"));

    // V3 소스맵 기본 필드 검증
    expect(map.version).toBe(3);
    expect(map.sources).toBeArray();
    expect(map.sources.length).toBeGreaterThanOrEqual(2);
    expect(map.mappings).toBeString();
    expect(map.mappings.length).toBeGreaterThan(0);

    // sourcesContent가 존재해야 한다
    expect(map.sourcesContent).toBeArray();
    expect(map.sourcesContent.length).toBe(map.sources.length);

    // 각 sourcesContent가 비어있지 않아야 한다
    for (const content of map.sourcesContent) {
      expect(typeof content).toBe("string");
      expect(content.length).toBeGreaterThan(0);
    }

    // 원본 소스 내용이 포함되어 있어야 한다
    const allContent = map.sourcesContent.join("\n");
    expect(allContent).toContain("function add");
    expect(allContent).toContain("console.log");
  });

  test("번들 출력에 sourceMappingURL이 포함된다", async () => {
    const fixture = await createFixture({
      "index.ts": `console.log("hello");`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile, "--sourcemap"]);

    const output = readFileSync(outFile, "utf-8");
    expect(output).toContain("//# sourceMappingURL=out.js.map");
  });

  test("--sources-content=false이면 sourcesContent가 없다", async () => {
    const fixture = await createFixture({
      "index.ts": `console.log("hello");`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--sourcemap",
      "--sources-content=false",
    ]);

    const mapPath = outFile + ".map";
    expect(existsSync(mapPath)).toBe(true);

    const map = JSON.parse(readFileSync(mapPath, "utf-8"));
    expect(map.sourcesContent).toBeUndefined();
  });

  test("소스맵 mappings가 유효한 VLQ이다", async () => {
    const fixture = await createFixture({
      "index.ts": `const x = 1;\nconst y = 2;\nconsole.log(x + y);`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    await runZts(["--bundle", join(fixture.dir, "index.ts"), "-o", outFile, "--sourcemap"]);

    const map = JSON.parse(readFileSync(outFile + ".map", "utf-8"));

    // mappings는 base64 VLQ 문자 + 세미콜론 + 콤마만 포함해야 한다
    const validChars = /^[A-Za-z0-9+/;,]*$/;
    expect(map.mappings).toMatch(validChars);

    // 세미콜론이 줄 구분자 — 최소 1줄 이상
    expect(map.mappings.length).toBeGreaterThan(0);
  });

  test("단일 파일 트랜스파일 소스맵", async () => {
    const fixture = await createFixture({
      "input.ts": `const x: number = 42;\nconsole.log(x);`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "output.js");
    const result = await runZts([join(fixture.dir, "input.ts"), "-o", outFile, "--sourcemap"]);
    expect(result.exitCode).toBe(0);

    const mapPath = outFile + ".map";
    expect(existsSync(mapPath)).toBe(true);

    const map = JSON.parse(readFileSync(mapPath, "utf-8"));
    expect(map.version).toBe(3);
    expect(map.sources.length).toBeGreaterThanOrEqual(1);
    expect(map.mappings.length).toBeGreaterThan(0);
  });

  test("다중 모듈 번들에서 sources에 모든 모듈이 포함된다", async () => {
    const fixture = await createFixture({
      "src/index.ts": `import { greet } from "./util";\nconsole.log(greet("world"));`,
      "src/util.ts": `export function greet(name: string): string {\n  return "hello " + name;\n}`,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "dist/out.js");
    await runZts(["--bundle", join(fixture.dir, "src/index.ts"), "-o", outFile, "--sourcemap"]);

    const map = JSON.parse(readFileSync(outFile + ".map", "utf-8"));

    // 두 모듈 모두 sources에 포함되어야 한다
    expect(map.sources.length).toBe(2);
    const joined = map.sources.join("|");
    expect(joined).toContain("index.ts");
    expect(joined).toContain("util.ts");

    // sourcesContent도 각 모듈의 내용을 포함해야 한다
    expect(map.sourcesContent.length).toBe(2);
    const allContent = map.sourcesContent.join("\n");
    expect(allContent).toContain("function greet");
  });
});
