import { spawn } from "bun";
import { mkdtemp, rm, writeFile, mkdir, symlink, stat } from "node:fs/promises";
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
///
/// symlink 자체는 존재하지 않는 target으로도 생성되므로, 먼저 target 존재를
/// 확인한 뒤에 심볼릭 링크를 만든다 (broken symlink 방지).
export async function linkNodeModules(dir: string, packages: string[]): Promise<void> {
  const nmDir = join(dir, "node_modules");
  await mkdir(nmDir, { recursive: true });
  const scopes = new Set(packages.filter((p) => p.startsWith("@")).map((p) => p.split("/")[0]));
  await Promise.all([...scopes].map((s) => mkdir(join(nmDir, s), { recursive: true })));
  await Promise.all(
    packages.map(async (pkg) => {
      for (const root of LOOKUP_ROOTS) {
        const target = join(root, pkg);
        try {
          await stat(join(target, "package.json"));
        } catch {
          continue;
        }
        try {
          await symlink(target, join(nmDir, pkg));
          return;
        } catch {}
      }
    }),
  );
}

interface RunOptions {
  env?: Record<string, string | undefined>;
}

async function runCmd(
  cmd: string[],
  options?: RunOptions,
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const spawnOpts: Parameters<typeof spawn>[0] = { cmd, stdout: "pipe", stderr: "pipe" };
  if (options?.env) spawnOpts.env = options.env as Record<string, string>;
  const proc = spawn(spawnOpts);

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);

  return { stdout, stderr, exitCode };
}

export async function runZts(
  args: string[],
  options?: RunOptions,
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  return runCmd([ZTS_BIN, ...args], options);
}

/// Node로 JS 파일을 실행. exit != 0 시 stdout/stderr를 포함한 에러 throw (디버깅 편의).
export async function runNode(file: string): Promise<{ stdout: string; stderr: string }> {
  const { stdout, stderr, exitCode } = await runCmd(["node", file]);
  if (exitCode !== 0) {
    throw new Error(
      `node '${file}' exited ${exitCode}\n--- stdout ---\n${stdout}\n--- stderr ---\n${stderr}`,
    );
  }
  return { stdout: stdout.trim(), stderr };
}

// ─── watch-json 테스트 공용 헬퍼 ───

/// `zts --watch-json ...`을 shell 경유로 spawn하고 stdout을 jsonOutPath로 리다이렉트.
/// bun test가 child process stdout pipe를 제대로 처리 못 해서 파일 리다이렉트 방식 사용.
export function spawnWatchJson(
  args: string[],
  jsonOutPath: string,
): import("node:child_process").ChildProcess {
  const { spawn: spawnChild } = require("node:child_process");
  const quoted = args.map((a) => `"${a}"`).join(" ");
  return spawnChild("sh", ["-c", `"${ZTS_BIN}" ${quoted} > "${jsonOutPath}" 2>/dev/null`]);
}

/// watch 프로세스를 kill하고 종료를 기다림. 2초 후 SIGKILL fallback — 좀비 방지.
export function killAndWait(proc: import("node:child_process").ChildProcess): Promise<void> {
  return new Promise<void>((resolve) => {
    if (proc.exitCode !== null) {
      resolve();
      return;
    }
    const timeout = setTimeout(() => {
      try {
        proc.kill("SIGKILL");
      } catch {}
      resolve();
    }, 2000);
    proc.on("exit", () => {
      clearTimeout(timeout);
      resolve();
    });
    proc.kill();
  });
}

/** 증분 파싱 상태 — waitForNdjsonLines의 offset/parsedCount를 호출부에서 유지하기 위함. */
export interface NdjsonTail<T = Record<string, unknown>> {
  parsed: T[];
  offset: number;
}

/** NdjsonTail 초기 상태. */
export function createNdjsonTail<T = Record<string, unknown>>(): NdjsonTail<T> {
  return { parsed: [], offset: 0 };
}

/// ndjson 파일을 폴링하며 `tail`에 새 라인을 누적 파싱. `minLines` 충족 시 반환.
/// 루프에서 호출하면 매번 전체 파일이 아닌 offset 이후만 재파싱 (O(N²) 방지).
export async function waitForNdjsonLines<T = Record<string, unknown>>(
  path: string,
  minLines: number,
  tail: NdjsonTail<T>,
  opts: { timeoutMs?: number; pollMs?: number } = {},
): Promise<T[]> {
  const timeoutMs = opts.timeoutMs ?? 10000;
  const pollMs = opts.pollMs ?? 100;
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    try {
      const buf = readFileSync(path, "utf8");
      if (buf.length > tail.offset) {
        // \n 기준 라인 분리. 부분 라인은 다음 폴링에서 처리.
        const newContent = buf.slice(tail.offset);
        const lastNl = newContent.lastIndexOf("\n");
        if (lastNl >= 0) {
          const complete = newContent.slice(0, lastNl);
          tail.offset += lastNl + 1;
          for (const line of complete.split("\n")) {
            if (!line) continue;
            try {
              tail.parsed.push(JSON.parse(line) as T);
            } catch {
              // 부분 라인이나 쓰기 중간 상태 — 스킵 (offset은 이미 이동)
            }
          }
        }
      }
      if (tail.parsed.length >= minLines) return tail.parsed;
    } catch {
      /* 파일 아직 없음 */
    }
    await new Promise((r) => setTimeout(r, pollMs));
  }
  throw new Error(
    `timeout waiting for ${minLines} ndjson lines in ${path} (got ${tail.parsed.length})`,
  );
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
