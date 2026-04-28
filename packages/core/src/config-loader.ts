/**
 * zts.config.{ts,mts,cts,mjs,js,cjs,json} 로더.
 *
 * `.ts/.mts/.cts` 는 NAPI `transpile()` 로 self-compile 후 dynamic import.
 * `.mjs/.js/.cjs` 는 직접 dynamic import. `.json` 은 readFileSync + JSON.parse.
 *
 * tmp 파일은 config 옆에 작성해 사용자의 node_modules resolution 을 보존한다
 * (esbuild `esbuild.config.bundled-*.mjs` 패턴).
 */

import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, extname, join, resolve as pathResolve } from "node:path";
import { pathToFileURL } from "node:url";

import type { BuildOptions } from "../index";
import { init, transpile } from "../index";

/** Phase 1: 객체만 지원. 함수형 (Vite 식 `({ command, mode, env }) => ...`) 은 #2103 (Phase 2-1) 에서 추가. */
export type UserConfig = Partial<BuildOptions>;

/**
 * 자동 탐색 우선순위. 동일 디렉토리에 다중 확장자 존재 시 첫 매치 반환.
 * 사용자가 의도적으로 여러 형식을 두는 경우는 거의 없으므로 silent precedence 로 충분.
 *
 * 같은 배열에서 `TS_EXTS`/`JS_EXTS` 를 derive — 새 확장자 추가 시 한 곳만 고침.
 */
export const CONFIG_EXT_PRIORITY = [".ts", ".mts", ".cts", ".mjs", ".js", ".cjs", ".json"] as const;

const TS_EXTS = new Set<string>(CONFIG_EXT_PRIORITY.slice(0, 3));
const JS_EXTS = new Set<string>(CONFIG_EXT_PRIORITY.slice(3, 6));

/**
 * config 파일을 로드한다. 확장자에 따라 self-compile 또는 직접 import.
 *
 * 존재 여부는 사전 stat 으로 확인하지 않고 실제 read/import 의 ENOENT 를 catch
 * 한다 — TOCTOU 회피 + 1 syscall 절감.
 *
 * @throws 파일이 없거나, 확장자가 지원되지 않거나, 컴파일/평가가 실패하면 throw.
 */
export async function loadConfig(filePath: string): Promise<UserConfig> {
  const absPath = pathResolve(filePath);
  const ext = extname(absPath).toLowerCase();

  if (ext === ".json") {
    return loadJsonConfig(absPath);
  }
  if (TS_EXTS.has(ext)) {
    return loadTsConfig(absPath);
  }
  if (JS_EXTS.has(ext)) {
    return loadJsConfig(absPath);
  }
  throw new Error(
    `@zts/core: unsupported config extension "${ext}" for ${absPath}. Supported: .ts/.mts/.cts/.mjs/.js/.cjs/.json`,
  );
}

function loadJsonConfig(absPath: string): UserConfig {
  const raw = readFileOrThrowNotFound(absPath);
  try {
    return JSON.parse(raw) as UserConfig;
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    throw new Error(`@zts/core: failed to parse JSON config ${absPath}: ${reason}`);
  }
}

async function loadTsConfig(absPath: string): Promise<UserConfig> {
  init();
  const source = readFileOrThrowNotFound(absPath);
  // ZTS parser 는 filename 의 `.cts` 확장자를 보고 CommonJS Script 모드로 진입해
  // 최상위 `export default` 를 거부한다 (`src/parser/parser.zig:283` 부근). 사용자가
  // `.cts` 에 `export default {...}` 를 쓴 의도는 TS 식 ESM 이므로 파싱 단계에서만
  // 가상의 `.ts` 로 호출한다 — 에러 메시지·sourcemap 에는 실제 경로가 그대로 사용된다.
  // FIXME: `transpile()` 에 `moduleType: "module"` 같은 명시 옵션이 추가되면 이전.
  const parseFilename = absPath.endsWith(".cts") ? absPath.slice(0, -4) + ".ts" : absPath;
  const result = transpile(source, {
    filename: parseFilename,
    format: "esm",
  });
  if (result.errors) {
    throw new Error(`@zts/core: config compile failed in ${absPath}\n${result.errors}`);
  }

  const tmpName = `.zts-config.bundled-${randomBytes(6).toString("hex")}.mjs`;
  const tmpPath = join(dirname(absPath), tmpName);
  writeFileSync(tmpPath, result.code, "utf8");
  try {
    return await importAndResolveDefault(tmpPath);
  } finally {
    try {
      unlinkSync(tmpPath);
    } catch (err) {
      const reason = err instanceof Error ? err.message : String(err);
      console.warn(`@zts/core: failed to remove tmp config ${tmpPath}: ${reason}`);
    }
  }
}

async function loadJsConfig(absPath: string): Promise<UserConfig> {
  return importAndResolveDefault(absPath);
}

async function importAndResolveDefault(absPath: string): Promise<UserConfig> {
  // 같은 프로세스에서 다중 reload 가 필요한 watch (#2107) 는 별도 cache-bust 적용 예정.
  const url = pathToFileURL(absPath).href;
  let mod: Record<string, unknown>;
  try {
    mod = await import(url);
  } catch (err) {
    const code = (err as NodeJS.ErrnoException | undefined)?.code;
    if (code === "ERR_MODULE_NOT_FOUND" || code === "ENOENT") {
      throw new Error(`@zts/core: config file not found: ${absPath}`);
    }
    throw err;
  }
  const config = (mod as { default?: unknown }).default ?? mod;
  if (typeof config !== "object" || config === null || Array.isArray(config)) {
    throw new Error(
      `@zts/core: config must export an object (got ${Array.isArray(config) ? "array" : typeof config}) from ${absPath}`,
    );
  }
  return config as UserConfig;
}

function readFileOrThrowNotFound(absPath: string): string {
  try {
    return readFileSync(absPath, "utf8");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") {
      throw new Error(`@zts/core: config file not found: ${absPath}`);
    }
    throw err;
  }
}

/**
 * cwd 에서 `zts.config.*` 자동 탐색. 우선순위는 `CONFIG_EXT_PRIORITY` 참조.
 *
 * 동기 stat (`existsSync`) 사용 — CLI 시작 시 한 번만 호출되므로 비용 무시 가능.
 * parent 디렉토리 traversal 은 모노레포 워크스페이스 (#2111 / Phase 3-4) 에서 처리.
 *
 * Note: Zig CLI (`src/main.zig:293` `applyZtsConfigJson`) 은 현재 `.json` 만
 * 직접 처리한다. 다른 확장자는 JS CLI (`zts.mjs`) 만 자동 탐색하므로 두 경로의
 * 동작이 의도적으로 갈린다. 통합은 #2105 (Phase 2-3 bundler 옵션 매핑) 에서.
 */
export function findConfigPath(cwd: string): string | null {
  for (const ext of CONFIG_EXT_PRIORITY) {
    const candidate = join(cwd, `zts.config${ext}`);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}
