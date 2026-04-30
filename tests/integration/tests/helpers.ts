import { spawn } from "bun";
import { mkdtemp, rm, writeFile, mkdir, symlink, stat } from "node:fs/promises";
import { readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const PROJECT_ROOT = resolve(import.meta.dir, "../../..");
export const ZTS_BIN = join(PROJECT_ROOT, "zig-out/bin/zts");
/// JS CLI (NAPI 기반). `compiler.emotion` / `compiler.styledComponents` 같은 JS-only
/// 옵션을 검증하려면 Zig CLI 대신 이 경로를 사용해야 함.
export const ZTS_JS_CLI = join(PROJECT_ROOT, "packages/core/bin/zts.mjs");
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
///
/// `extraRoots` 옵션: 기본 LOOKUP_ROOTS 보다 우선해서 검색할 추가 root.
/// 격리 fixture (예: emotion v10) 의 node_modules 를 v11 보다 먼저 매칭하기 위함.
export async function linkNodeModules(
  dir: string,
  packages: string[],
  options: { extraRoots?: string[] } = {},
): Promise<void> {
  const roots = [...(options.extraRoots ?? []), ...LOOKUP_ROOTS];
  const nmDir = join(dir, "node_modules");
  await mkdir(nmDir, { recursive: true });
  const scopes = new Set(packages.filter((p) => p.startsWith("@")).map((p) => p.split("/")[0]));
  await Promise.all([...scopes].map((s) => mkdir(join(nmDir, s), { recursive: true })));
  await Promise.all(
    packages.map(async (pkg) => {
      for (const root of roots) {
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

/// emotion v10 격리 fixture (`tests/integration/fixtures/emotion-v10/node_modules`).
/// `linkNodeModules({ extraRoots: [EMOTION_V10_FIXTURE_NODE_MODULES] })` 형태로 사용.
export const EMOTION_V10_FIXTURE_NODE_MODULES = resolve(
  import.meta.dir,
  "../fixtures/emotion-v10/node_modules",
);

/// emotion v10 fixture 가 설치돼 있는지 검사 — `bun install` 이 실행됐는지.
/// CI 에서 fixture install 을 빼먹은 경우 `describe.skipIf` 로 우회 가능.
export function hasEmotionV10Fixture(): boolean {
  try {
    statSync(join(EMOTION_V10_FIXTURE_NODE_MODULES, "@emotion/core/package.json"));
    return true;
  } catch {
    return false;
  }
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

/// Transpile-only (no `--bundle`) helper. ZTS 의 *transpile* path 단독 동작을
/// 격리 검증할 때 사용. `bundleAndRun` 은 `--bundle` 을 강제하므로 inner-name
/// elision 같은 별도 pass 와 섞여 transpile 단독 동작을 잡아내기 어렵다 (#2194,
/// #2197). source 를 임시 파일에 쓰고 ZTS 로 트랜스파일 → bun 으로 실행 → stdout/stderr
/// 비교를 한 번에.
export async function transpileAndRun(
  source: string,
  extraArgs: string[] = [],
  opts: { ext?: "ts" | "tsx" | "js" | "jsx" } = {},
): Promise<{
  transpileExitCode: number;
  transpileStderr: string;
  runOutput: string;
  runStderr: string;
  cleanup: () => Promise<void>;
}> {
  const dir = await mkdtemp(join(tmpdir(), "zts-transpile-"));
  const inFile = join(dir, `in.${opts.ext ?? "ts"}`);
  const outFile = join(dir, "out.js");
  await writeFile(inFile, source);
  const r = await runZts([inFile, "-o", outFile, ...extraArgs]);
  const exec = await runCmd(["bun", "run", outFile]);
  return {
    transpileExitCode: r.exitCode,
    transpileStderr: r.stderr,
    runOutput: exec.stdout.trimEnd(),
    runStderr: exec.stderr.trimEnd(),
    cleanup: async () => rm(dir, { recursive: true, force: true }),
  };
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

/// `bin` 옵션:
///   - `"zig"` (기본) — Zig CLI (`zts` 바이너리). 빠르고 standalone.
///   - `"js"` — JS CLI (`packages/core/bin/zts.mjs` via bun). NAPI 기반.
///     `compiler.emotion` / `compiler.styledComponents` 같은 JS-only 옵션이
///     `zts.config.json` 으로부터 NAPI 로 forward 되는지 검증할 때 사용.
export async function runZtsInDir(
  dir: string,
  args: string[],
  options: { bin?: "zig" | "js" } = {},
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const cmd = options.bin === "js" ? ["bun", ZTS_JS_CLI, ...args] : [ZTS_BIN, ...args];
  const proc = spawn({ cmd, stdout: "pipe", stderr: "pipe", cwd: dir });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { stdout, stderr, exitCode };
}

/// `zts.config.json` / CLI flag 통합 테스트의 `mkdtempSync → write → runZtsInDir`
/// 보일러플레이트 흡수. caller 는 `cleanup` 만 afterEach 에 등록하면 됨.
///
/// `--bundle <entry>` 와 `-o outFile` (또는 `--outdir outDir`) 은 자동 주입 — caller 는
/// 추가 옵션만 `args` 에 전달. `outDir` 명시 시 outFile 대신 outdir 모드.
export async function runConfigBundle(opts: {
  files: Record<string, string>;
  /** entry 상대 경로 (fixture dir 기준). 기본 `index.ts`. */
  entry?: string;
  /** 추가 CLI 옵션 (`--bundle` / `-o` / `--outdir` 은 자동 주입). */
  args?: string[];
  /** outdir 모드 명시 (없으면 `-o out.js` 모드). */
  outDir?: string;
}): Promise<{
  dir: string;
  /** `-o` 모드에서 set. outDir 모드면 undefined. */
  outFile?: string;
  /** `--outdir` 모드에서 set. 기본 모드면 undefined. */
  outDir?: string;
  stdout: string;
  stderr: string;
  exitCode: number;
  cleanup: () => Promise<void>;
}> {
  const { dir, cleanup } = await createFixture(opts.files);
  const entry = opts.entry ?? "index.ts";
  const useOutDir = opts.outDir !== undefined;
  const outFile = useOutDir ? undefined : join(dir, "out.js");
  const outDir = useOutDir ? join(dir, opts.outDir!) : undefined;
  const ioArgs = useOutDir ? ["--outdir", outDir!] : ["-o", outFile!];
  const result = await runZtsInDir(dir, [
    "--bundle",
    join(dir, entry),
    ...ioArgs,
    ...(opts.args ?? []),
  ]);
  return { dir, outFile, outDir, ...result, cleanup };
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
      bundleOutput: readFileSync(outFile, "utf-8"),
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
