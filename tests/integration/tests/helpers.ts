import { spawn } from "bun";
import { mkdtemp, rm, writeFile, mkdir, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const PROJECT_ROOT = resolve(import.meta.dir, "../../..");
export const ZTS_BIN = join(PROJECT_ROOT, "zig-out/bin/zts");
const INTEGRATION_NODE_MODULES = resolve(import.meta.dir, "../node_modules");

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

const REACT_STUB =
  "exports.useState = function(init) { return [init, function() {}]; };\n" +
  "exports.useEffect = function() {};\n" +
  "exports.useMemo = function(fn) { return fn(); };\n" +
  "exports.useRef = function(init) { return { current: init }; };\n" +
  "exports.useCallback = function(fn) { return fn; };\n" +
  "exports.useContext = function() { return null; };\n" +
  "exports.useReducer = function(_, init) { return [init, function() {}]; };\n" +
  "exports.createElement = function() { return {}; };\n" +
  "exports.createContext = function() { return { Provider: null, Consumer: null }; };\n" +
  "exports.Fragment = Symbol('Fragment');\n" +
  "exports.forwardRef = function(fn) { return fn; };\n" +
  "exports.memo = function(c) { return c; };\n" +
  "module.exports.default = exports;\n";

/// `react`만 stub으로 필요한 fixture (RSC, sourcemap 등). 실제 react 패키지를 install
/// 하지 않아도 import만 resolve되면 충분한 케이스용. fixture에 더 많은 패키지가 필요하면
/// `linkNodeModules`로 PROJECT_ROOT의 node_modules를 symlink해 사용한다.
export async function createReactStubFixture(
  files: Record<string, string>,
): Promise<{ dir: string; cleanup: () => Promise<void> }> {
  return createFixture({
    "node_modules/react/package.json": '{"name": "react", "main": "index.js"}',
    "node_modules/react/index.js": REACT_STUB,
    ...files,
  });
}

/// 실제 패키지를 fixture dir로 symlink. plugin host(Node)가 직접 dynamic import할 때
/// (예: Vue/Svelte plugin이 `vue/compiler-sfc`를 가져올 때) 사용.
/// PROJECT_ROOT/node_modules 우선, 없으면 tests/integration/node_modules 시도.
/// emotion 같은 transitive deps는 hoist 안 되므로 tests/integration devDep에서 link.
export async function linkNodeModules(dir: string, packages: string[]): Promise<void> {
  const nmDir = join(dir, "node_modules");
  await mkdir(nmDir, { recursive: true });
  const roots = [join(PROJECT_ROOT, "node_modules"), INTEGRATION_NODE_MODULES];
  for (const pkg of packages) {
    if (pkg.startsWith("@")) {
      await mkdir(join(nmDir, pkg.split("/")[0]), { recursive: true });
    }
    for (const root of roots) {
      const src = join(root, pkg);
      try {
        await symlink(src, join(nmDir, pkg));
        break;
      } catch {}
    }
  }
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
