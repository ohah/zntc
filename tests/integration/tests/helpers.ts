import { spawn } from "bun";
import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const PROJECT_ROOT = resolve(import.meta.dir, "../../..");
export const ZTS_BIN = join(PROJECT_ROOT, "zig-out/bin/zts");

export async function createFixture(
  files: Record<string, string>,
): Promise<{ dir: string; cleanup: () => Promise<void> }> {
  const dir = await mkdtemp(join(tmpdir(), "zts-integration-"));

  await Promise.all(
    Object.entries(files).map(async ([name, content]) => {
      const filePath = join(dir, name);
      await mkdir(dirname(filePath), { recursive: true });
      await writeFile(filePath, content);
    }),
  );

  return {
    dir,
    cleanup: () => rm(dir, { recursive: true, force: true }),
  };
}

const RN_ASSET_REGISTRY_STUB =
  "module.exports = { registerAsset: function(a) { return a; }, getAssetByID: function() { return null; } };\n";

/// RN 프리셋 사용 fixture 생성 — `react-native/Libraries/Image/AssetRegistry`가 자동 주입되므로
/// fixture 안에 stub 모듈을 미리 만들어 둬야 unresolved_import 진단(에러)이 발생하지 않는다.
export async function createRNFixture(
  files: Record<string, string>,
): Promise<{ dir: string; cleanup: () => Promise<void> }> {
  return createFixture({
    "node_modules/react-native/Libraries/Image/AssetRegistry.js": RN_ASSET_REGISTRY_STUB,
    "node_modules/react-native/package.json": '{"name": "react-native", "main": "index.js"}',
    ...files,
  });
}

async function runCmd(
  cmd: string[],
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const proc = spawn({ cmd, stdout: "pipe", stderr: "pipe" });

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);

  return { stdout, stderr, exitCode };
}

export async function runZts(
  args: string[],
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  return runCmd([ZTS_BIN, ...args]);
}

export async function runZtsInDir(
  dir: string,
  args: string[],
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const proc = spawn({ cmd: [ZTS_BIN, ...args], stdout: "pipe", stderr: "pipe", cwd: dir });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { stdout, stderr, exitCode };
}

export async function bundleAndRun(
  files: Record<string, string>,
  entry: string = "index.ts",
  extraArgs: string[] = [],
): Promise<{
  bundleOutput: string;
  runOutput: string;
  runStderr: string;
  exitCode: number;
  cleanup: () => Promise<void>;
}> {
  const { dir, cleanup } = await createFixture(files);
  const outFile = join(dir, "out.js");

  try {
    const bundle = await runZts(["--bundle", join(dir, entry), "-o", outFile, ...extraArgs]);

    if (bundle.exitCode !== 0) {
      throw new Error(`ZTS bundle failed: ${bundle.stderr}`);
    }

    const run = await runCmd(["bun", "run", outFile]);

    return {
      bundleOutput: bundle.stdout,
      runOutput: run.stdout.trim(),
      runStderr: run.stderr,
      exitCode: run.exitCode,
      cleanup,
    };
  } catch (e) {
    await cleanup();
    throw e;
  }
}
