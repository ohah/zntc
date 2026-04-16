import { spawn } from "bun";
import { mkdtemp, rm, writeFile, mkdir, symlink } from "node:fs/promises";
import { readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const PROJECT_ROOT = resolve(import.meta.dir, "../../..");
export const ZTS_BIN = join(PROJECT_ROOT, "zig-out/bin/zts");
const INTEGRATION_NODE_MODULES = resolve(import.meta.dir, "../node_modules");
const LOOKUP_ROOTS = [join(PROJECT_ROOT, "node_modules"), INTEGRATION_NODE_MODULES];

/// PROJECT_ROOT/node_modules 우선, tests/integration/node_modules fallback으로 패키지 존재 검사.
export function hasPackage(name: string): boolean {
  for (const root of LOOKUP_ROOTS) {
    try {
      statSync(join(root, name, "package.json"));
      return true;
    } catch {}
  }
  return false;
}

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

// fixture 파일에 영구 commit된 stub을 single source로 사용 (TanStack 테스트와 공유).
const REACT_STUB = readFileSync(
  resolve(import.meta.dir, "fixtures/rsc-directives/node_modules/react/index.js"),
  "utf-8",
);

/// react import만 resolve되면 충분한 케이스(RSC, sourcemap 등)용 react stub fixture.
/// 더 많은 패키지가 필요하면 linkNodeModules 활용.
export async function createReactStubFixture(
  files: Record<string, string>,
): Promise<{ dir: string; cleanup: () => Promise<void> }> {
  return createFixture({
    "node_modules/react/package.json": '{"name": "react", "main": "index.js"}',
    "node_modules/react/index.js": REACT_STUB,
    ...files,
  });
}

/// LOOKUP_ROOTS에서 패키지를 찾아 fixture dir로 symlink. 패키지 단위 병렬 실행.
/// plugin host의 dynamic import + ZTS 번들 resolve 양쪽에서 사용.
export async function linkNodeModules(dir: string, packages: string[]): Promise<void> {
  const nmDir = join(dir, "node_modules");
  await mkdir(nmDir, { recursive: true });
  const scopes = new Set(packages.filter((p) => p.startsWith("@")).map((p) => p.split("/")[0]));
  await Promise.all([...scopes].map((s) => mkdir(join(nmDir, s), { recursive: true })));
  await Promise.all(
    packages.map(async (pkg) => {
      for (const root of LOOKUP_ROOTS) {
        try {
          await symlink(join(root, pkg), join(nmDir, pkg));
          return;
        } catch {}
      }
    }),
  );
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
