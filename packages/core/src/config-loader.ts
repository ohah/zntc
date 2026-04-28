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

const TS_EXTS = new Set([".ts", ".mts", ".cts"]);
const JS_EXTS = new Set([".mjs", ".js", ".cjs"]);

/**
 * config 파일을 로드한다. 확장자에 따라 self-compile 또는 직접 import.
 *
 * @throws path 가 존재하지 않거나, 확장자가 지원되지 않거나, 컴파일/평가가 실패하면 throw.
 */
export async function loadConfig(filePath: string): Promise<UserConfig> {
  const absPath = pathResolve(filePath);
  if (!existsSync(absPath)) {
    throw new Error(`@zts/core: config file not found: ${absPath}`);
  }

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
  const raw = readFileSync(absPath, "utf8");
  try {
    return JSON.parse(raw) as UserConfig;
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    throw new Error(`@zts/core: failed to parse JSON config ${absPath}: ${reason}`);
  }
}

async function loadTsConfig(absPath: string): Promise<UserConfig> {
  init();
  const source = readFileSync(absPath, "utf8");
  // ZTS 는 `.cts` 를 CommonJS-only TS 로 취급해 ESM 구문을 거부한다.
  // 사용자가 `.cts` 에 `export default {...}` 를 쓴 의도는 TS 식 ESM 이므로
  // 파싱 단계에서만 `.ts` 로 가장한다 (에러 메시지에는 실제 경로 사용).
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
    } catch {
      // 삭제 실패는 무시 — 사용자가 추후 정리 가능
    }
  }
}

async function loadJsConfig(absPath: string): Promise<UserConfig> {
  return importAndResolveDefault(absPath);
}

async function importAndResolveDefault(absPath: string): Promise<UserConfig> {
  // cache-bust 쿼리: watch 모드에서 같은 경로의 config 가 재로드되어야 한다.
  const url = pathToFileURL(absPath).href + `?t=${Date.now()}`;
  const mod = await import(url);
  const config = (mod as { default?: unknown }).default ?? mod;
  if (typeof config !== "object" || config === null || Array.isArray(config)) {
    throw new Error(
      `@zts/core: config must export an object (got ${Array.isArray(config) ? "array" : typeof config}) from ${absPath}`,
    );
  }
  return config as UserConfig;
}
