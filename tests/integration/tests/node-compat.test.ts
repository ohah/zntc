import { describe, test, expect, afterEach } from "bun:test";
import { createFixture, runNode, runZts, runZtsInDir } from "./helpers";
import { join, basename } from "node:path";
import { realpathSync, symlinkSync } from "node:fs";

/// CJS/Node 프리셋으로 번들하고 outFile 경로 반환. 번들 실패 시 throw.
async function bundleCjsNode(dir: string, entry: string, outName = "out.cjs"): Promise<string> {
  const outFile = join(dir, outName);
  const bundle = await runZts([
    "--bundle",
    join(dir, entry),
    "--format=cjs",
    "--platform=node",
    "-o",
    outFile,
  ]);
  if (bundle.exitCode !== 0) {
    throw new Error(`zts bundle failed: ${bundle.stderr}`);
  }
  return outFile;
}

describe("Node.js 호환 edge case", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  describe("import.meta.* (ESM → CJS 치환)", () => {
    test("import.meta.url → pathToFileURL(__filename).href", async () => {
      const f = await createFixture({ "app.ts": `console.log(import.meta.url);` });
      cleanup = f.cleanup;

      const outFile = await bundleCjsNode(f.dir, "app.ts");
      const run = await runNode(outFile);

      // Node가 실제로 실행한 결과: file:// URL이어야 함
      expect(run.stdout).toMatch(/^file:\/\//);
      expect(run.stdout).toContain(basename(outFile));
    });

    test("import.meta.dirname → __dirname (Node는 realpath 기준)", async () => {
      const f = await createFixture({ "app.ts": `console.log(import.meta.dirname);` });
      cleanup = f.cleanup;

      const outFile = await bundleCjsNode(f.dir, "app.ts");
      const run = await runNode(outFile);

      expect(run.stdout).toBe(realpathSync(f.dir));
    });

    test("import.meta.filename → __filename", async () => {
      const f = await createFixture({ "app.ts": `console.log(import.meta.filename);` });
      cleanup = f.cleanup;

      const outFile = await bundleCjsNode(f.dir, "app.ts");
      const run = await runNode(outFile);

      expect(run.stdout).toBe(realpathSync(outFile));
    });
  });

  describe("심볼릭 링크 (entry)", () => {
    test("symlink를 통해 entry를 번들해도 실행 결과가 동일하다", async () => {
      const f = await createFixture({
        "real/app.ts": `console.log("hello", typeof import.meta.url);`,
      });
      cleanup = f.cleanup;

      // fixture는 매번 새 temp dir이라 존재 체크 불필요
      const linkEntry = join(f.dir, "link-app.ts");
      symlinkSync(join(f.dir, "real/app.ts"), linkEntry);

      const outFile = join(f.dir, "out.cjs");
      const bundle = await runZts([
        "--bundle",
        linkEntry,
        "--format=cjs",
        "--platform=node",
        "-o",
        outFile,
      ]);
      if (bundle.exitCode !== 0) throw new Error(`zts bundle failed: ${bundle.stderr}`);

      const run = await runNode(outFile);
      expect(run.stdout).toBe("hello string");
    });
  });

  describe("상대 경로 entry", () => {
    test("cwd 기준 상대 경로로 번들해도 동작한다", async () => {
      const f = await createFixture({ "sub/app.ts": `console.log("rel ok");` });
      cleanup = f.cleanup;

      const outFile = join(f.dir, "out.cjs");
      const bundle = await runZtsInDir(f.dir, [
        "--bundle",
        "./sub/app.ts",
        "--format=cjs",
        "--platform=node",
        "-o",
        outFile,
      ]);
      if (bundle.exitCode !== 0) throw new Error(`zts bundle failed: ${bundle.stderr}`);

      const run = await runNode(outFile);
      expect(run.stdout).toBe("rel ok");
    });
  });

  describe("ESM 출력", () => {
    test("ESM 출력에서 import.meta.url은 변환하지 않고 Node가 제공", async () => {
      const f = await createFixture({
        "app.ts": `console.log(import.meta.url);`,
        "package.json": `{"type": "module"}`,
      });
      cleanup = f.cleanup;

      const outFile = join(f.dir, "out.mjs");
      const bundle = await runZts([
        "--bundle",
        join(f.dir, "app.ts"),
        "--format=esm",
        "--platform=node",
        "-o",
        outFile,
      ]);
      if (bundle.exitCode !== 0) throw new Error(`zts bundle failed: ${bundle.stderr}`);

      const run = await runNode(outFile);
      expect(run.stdout).toMatch(/^file:\/\//);
      expect(run.stdout).toContain(basename(outFile));
    });
  });
});
