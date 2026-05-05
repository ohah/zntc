import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";

import { joinUrl } from "../url.ts";
import { collectAppFiles, type NodeRequire, requireFromAppRoot } from "./loader.ts";

// 순서는 zts.mjs L892-902 와 동일 — postcss.config.* 이 .postcssrc.* 보다 우선.
// PR #5e 의 redirect 시점까지 양쪽 sync 유지 (#2539).
export const POSTCSS_CONFIG_NAMES: readonly string[] = [
  "postcss.config.mjs",
  "postcss.config.js",
  "postcss.config.cjs",
  "postcss.config.json",
  ".postcssrc",
  ".postcssrc.json",
  ".postcssrc.js",
  ".postcssrc.cjs",
  ".postcssrc.mjs",
];

export const isCssFile = (path: string): boolean => path.endsWith(".css");

export function isPostcssConfigFile(path: string): boolean {
  return POSTCSS_CONFIG_NAMES.includes(basename(path));
}

/** `root` 디렉토리에 postcss config 가 있으면 절대 path 반환, 없으면 null. */
export function findPostcssConfig(root: string): string | null {
  for (const name of POSTCSS_CONFIG_NAMES) {
    const path = join(root, name);
    if (existsSync(path)) return path;
  }
  return null;
}

export interface PostcssMessage {
  type?: string;
  file?: unknown;
  dir?: unknown;
  directory?: unknown;
}

/** postcss result.messages 에서 dep 트래킹용 file/dir 항목을 set 에 누적. */
export function collectPostcssMessages(
  messages: readonly PostcssMessage[] | null | undefined,
  deps: Set<string>,
  dirDeps: Set<string>,
): void {
  if (!messages) return;
  for (const message of messages) {
    if (message.type === "dependency" && typeof message.file === "string") {
      deps.add(resolve(message.file));
    }
    if (message.type === "dir-dependency") {
      const dir =
        (typeof message.dir === "string" && message.dir) ||
        (typeof message.directory === "string" && message.directory);
      if (dir) dirDeps.add(resolve(dir));
    }
    if (message.type === "context-dependency" && typeof message.file === "string") {
      deps.add(resolve(message.file));
    }
  }
}

export function logPostcssProcessed(
  logLevel: string | undefined,
  count: number,
  configFile: string | null | undefined,
): void {
  if (logLevel === "silent") return;
  console.error(
    `[postcss] processed ${count} CSS file(s) using ${basename(configFile ?? "postcss config")}`,
  );
}

interface LoadedPostcss {
  postcss: (plugins: unknown[]) => {
    process: (input: string, options: unknown) => Promise<PostcssResult>;
  };
  plugins: unknown[];
  options: Record<string, unknown>;
  configFile: string | null;
}

interface PostcssResult {
  css: string;
  map?: { toString(): string };
  messages?: PostcssMessage[];
}

interface PostcssrcConfig {
  plugins?: unknown[];
  options?: Record<string, unknown>;
  file?: string;
}

interface ConfigEnv {
  mode: string;
}

/**
 * postcss + postcss-load-config 를 app-first / fallback-second 로 require 후
 * config 로드. config 없거나 plugin 0 이면 null.
 *
 * `fallbackRequire` 는 caller 의 CLI context — postcss/postcss-load-config 를
 * app 이 갖지 않을 때 fallback (e.g. ZTS CLI 의 node_modules).
 */
export async function loadPostcssConfig(
  root: string,
  configEnv: ConfigEnv,
  fallbackRequire: NodeRequire,
): Promise<LoadedPostcss | null> {
  const postcssrc = requireFromAppRoot(root, fallbackRequire, "postcss-load-config") as (
    env: { cwd: string; env: string },
    root: string,
  ) => Promise<PostcssrcConfig>;
  const postcssModule = requireFromAppRoot(root, fallbackRequire, "postcss") as {
    default?: LoadedPostcss["postcss"];
  } & LoadedPostcss["postcss"];
  const postcss = (postcssModule.default ?? postcssModule) as LoadedPostcss["postcss"];
  const config = await postcssrc({ cwd: root, env: configEnv.mode }, root).catch((err) => {
    if ((err as { message?: string })?.message?.includes("No PostCSS Config found")) return null;
    throw err;
  });
  if (!config) return null;
  const plugins = config.plugins ?? [];
  if (plugins.length === 0) return null;
  return {
    postcss,
    plugins,
    options: config.options ?? {},
    configFile: config.file ?? null,
  };
}

/**
 * `cssDir` 의 모든 CSS 파일 (skipDir 제외) 에 postcss 실행 → in-place 덮어쓰기.
 * postcss config 가 없으면 no-op. `runPostcssForAppDev` 와 달리 outdir 분리 안 함.
 */
export async function runPostcssIfConfigured(
  root: string,
  cssDir: string,
  skipDir: string | null,
  configEnv: ConfigEnv,
  logLevel: string | undefined,
  fallbackRequire: NodeRequire,
): Promise<void> {
  const loaded = await loadPostcssConfig(root, configEnv, fallbackRequire);
  if (!loaded) return;
  const cssFiles = collectAppFiles(cssDir, { skipDir, predicate: isCssFile });
  await Promise.all(
    cssFiles.map(async (file) => {
      const input = readFileSync(file, "utf8");
      const result = await loaded.postcss(loaded.plugins).process(input, {
        ...loaded.options,
        from: file,
        to: file,
      });
      writeFileSync(file, result.css);
      if (result.map) writeFileSync(`${file}.map`, result.map.toString());
    }),
  );
  logPostcssProcessed(logLevel, cssFiles.length, loaded.configFile);
}

export interface AppDevPostcssOptions {
  root: string;
  outdir: string;
  configEnv: ConfigEnv;
  logLevel: string | undefined;
  base: string | undefined;
  changedPath?: string | null;
  fallbackRequire: NodeRequire;
}

export interface AppDevPostcssResult {
  deps: Set<string>;
  dirDeps: Set<string>;
  primaryHref: string | null;
  processed: number;
}

/**
 * Dev 모드 — `root` 의 CSS 파일들을 `outdir` 의 같은 rel path 로 emit (postcss
 * pipeline 적용). config 없으면 첫 CSS 의 primaryHref 만 반환. 단일 변경 (.css)
 * 이면 해당 파일만 reprocess, 그 외엔 전체.
 */
export async function runPostcssForAppDev(
  options: AppDevPostcssOptions,
): Promise<AppDevPostcssResult> {
  const { root, outdir, configEnv, logLevel, base, changedPath = null, fallbackRequire } = options;
  const deps = new Set<string>();
  const dirDeps = new Set<string>();
  let primaryHref: string | null = null;
  const configPath = findPostcssConfig(root);
  if (!configPath) {
    const first = collectAppFiles(root, { skipDir: outdir, predicate: isCssFile })[0];
    if (first) primaryHref = joinUrl(base, relative(root, first));
    return { deps, dirDeps, primaryHref, processed: 0 };
  }

  const loaded = await loadPostcssConfig(root, configEnv, fallbackRequire);
  if (!loaded) return { deps, dirDeps, primaryHref, processed: 0 };
  deps.add(resolve(loaded.configFile ?? configPath));

  mkdirSync(outdir, { recursive: true });
  const allCssFiles = collectAppFiles(root, { skipDir: outdir, predicate: isCssFile });
  const targets =
    changedPath && changedPath.endsWith(".css") && allCssFiles.includes(changedPath)
      ? [changedPath]
      : allCssFiles;

  await Promise.all(
    targets.map(async (file) => {
      const outputRel = relative(root, file);
      const outputPath = join(outdir, outputRel);
      mkdirSync(dirname(outputPath), { recursive: true });
      const input = readFileSync(file, "utf8");
      const result = await loaded.postcss(loaded.plugins).process(input, {
        ...loaded.options,
        from: file,
        to: outputPath,
      });
      writeFileSync(outputPath, result.css);
      if (result.map) writeFileSync(`${outputPath}.map`, result.map.toString());
      deps.add(resolve(file));
      collectPostcssMessages(result.messages, deps, dirDeps);
    }),
  );
  if (allCssFiles.length > 0) primaryHref = joinUrl(base, relative(root, allCssFiles[0]!));

  logPostcssProcessed(logLevel, targets.length, loaded.configFile);
  return { deps, dirDeps, primaryHref, processed: targets.length };
}
