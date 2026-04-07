import { describe, test, expect, afterEach } from "bun:test";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { createFixture, runZts } from "./helpers";
import { spawn } from "bun";

describe("preserve-modules", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("기본: 모듈 1개 = 출력 파일 1개, 디렉토리 구조 유지", async () => {
    const { dir, cleanup: c } = await createFixture({
      "src/index.ts": `
        import { add } from './lib/math';
        console.log(add(1, 2));
      `,
      "src/lib/math.ts": `
        export function add(a: number, b: number): number {
          return a + b;
        }
      `,
    });
    cleanup = c;

    const outdir = join(dir, "dist");
    const result = await runZts([
      "--bundle",
      join(dir, "src/index.ts"),
      "--preserve-modules",
      `--preserve-modules-root=${join(dir, "src")}`,
      "--outdir",
      outdir,
    ]);

    expect(result.stderr).toBe("");
    expect(result.exitCode).toBe(0);
    expect(existsSync(join(outdir, "index.js"))).toBe(true);
    expect(existsSync(join(outdir, "lib/math.js"))).toBe(true);
  });

  test("import 경로가 상대 경로로 올바르게 재작성됨", async () => {
    const { dir, cleanup: c } = await createFixture({
      "src/index.ts": `
        import { greet } from './utils';
        console.log(greet("world"));
      `,
      "src/utils.ts": `
        export function greet(name: string): string {
          return "Hello, " + name;
        }
      `,
    });
    cleanup = c;

    const outdir = join(dir, "dist");
    await runZts([
      "--bundle",
      join(dir, "src/index.ts"),
      "--preserve-modules",
      `--preserve-modules-root=${join(dir, "src")}`,
      "--outdir",
      outdir,
    ]);

    const indexContent = readFileSync(join(outdir, "index.js"), "utf-8");
    expect(indexContent).toContain("./utils.js");
  });

  test("다른 디렉토리 간 import 경로가 올바른 상대 경로", async () => {
    const { dir, cleanup: c } = await createFixture({
      "src/index.ts": `
        import { add } from './lib/math';
        console.log(add(1, 2));
      `,
      "src/lib/math.ts": `
        export function add(a: number, b: number): number { return a + b; }
      `,
    });
    cleanup = c;

    const outdir = join(dir, "dist");
    await runZts([
      "--bundle",
      join(dir, "src/index.ts"),
      "--preserve-modules",
      `--preserve-modules-root=${join(dir, "src")}`,
      "--outdir",
      outdir,
    ]);

    const indexContent = readFileSync(join(outdir, "index.js"), "utf-8");
    expect(indexContent).toContain("./lib/math.js");
  });

  test("런타임 동작 정상", async () => {
    const { dir, cleanup: c } = await createFixture({
      "src/index.ts": `
        import { add } from './lib/math';
        import { greet } from './lib/utils';
        console.log(add(1, 2));
        console.log(greet("world"));
      `,
      "src/lib/math.ts": `
        export function add(a: number, b: number): number { return a + b; }
        export function subtract(a: number, b: number): number { return a - b; }
      `,
      "src/lib/utils.ts": `
        import { add } from './math';
        export function greet(name: string): string { return "Hello, " + name + "! " + add(1, 1); }
      `,
    });
    cleanup = c;

    const outdir = join(dir, "dist");
    await runZts([
      "--bundle",
      join(dir, "src/index.ts"),
      "--preserve-modules",
      `--preserve-modules-root=${join(dir, "src")}`,
      "--outdir",
      outdir,
    ]);

    const proc = spawn({
      cmd: ["bun", "run", join(outdir, "index.js")],
      stdout: "pipe",
      stderr: "pipe",
    });
    const stdout = await new Response(proc.stdout).text();
    await proc.exited;

    const lines = stdout.trim().split("\n");
    expect(lines[0]).toBe("3");
    expect(lines[1]).toBe("Hello, world! 2");
  });

  test("export 중복 없음 (cross-chunk export 스킵)", async () => {
    const { dir, cleanup: c } = await createFixture({
      "src/index.ts": `
        import { add } from './math';
        console.log(add(1, 2));
      `,
      "src/math.ts": `
        export function add(a: number, b: number): number { return a + b; }
        export function subtract(a: number, b: number): number { return a - b; }
      `,
    });
    cleanup = c;

    const outdir = join(dir, "dist");
    await runZts([
      "--bundle",
      join(dir, "src/index.ts"),
      "--preserve-modules",
      `--preserve-modules-root=${join(dir, "src")}`,
      "--outdir",
      outdir,
    ]);

    const mathContent = readFileSync(join(outdir, "math.js"), "utf-8");
    const exportCount = (mathContent.match(/^export\s*\{/gm) || []).length;
    expect(exportCount).toBe(1);
  });

  test("--preserve-modules without --outdir → 에러", async () => {
    const { dir, cleanup: c } = await createFixture({
      "index.ts": `console.log("hello");`,
    });
    cleanup = c;

    const result = await runZts(["--bundle", join(dir, "index.ts"), "--preserve-modules"]);

    expect(result.stderr).toContain("--preserve-modules requires --outdir");
  });

  test("preserve-modules-root 없이도 동작 (파일명만 사용)", async () => {
    const { dir, cleanup: c } = await createFixture({
      "src/index.ts": `
        import { add } from './math';
        console.log(add(1, 2));
      `,
      "src/math.ts": `
        export function add(a: number, b: number): number { return a + b; }
      `,
    });
    cleanup = c;

    const outdir = join(dir, "dist");
    const result = await runZts([
      "--bundle",
      join(dir, "src/index.ts"),
      "--preserve-modules",
      "--outdir",
      outdir,
    ]);

    expect(result.exitCode).toBe(0);
    expect(existsSync(join(outdir, "index.js"))).toBe(true);
    expect(existsSync(join(outdir, "math.js"))).toBe(true);
  });
});
