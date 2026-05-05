import { readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, extname } from "node:path";

import { type NodeRequire, requireFromAppRoot } from "./loader.ts";

interface SassCompiler {
  compile: (file: string, options: SassCompileOptions) => SassCompileResult;
}

interface SassCompileOptions {
  style?: "expanded" | "compressed";
  loadPaths?: string[];
  sourceMap?: boolean;
}

interface SassCompileResult {
  css: string;
}

export const CSS_PREPROCESSOR_EXTENSIONS: ReadonlySet<string> = new Set([".scss", ".sass"]);
const MODULE_PREPROCESSOR_RE = /\.module\.(?:scss|sass)$/;

export function isCssPreprocessorFile(path: string): boolean {
  return CSS_PREPROCESSOR_EXTENSIONS.has(extname(path));
}

export function isCssModulePreprocessorFile(path: string): boolean {
  return MODULE_PREPROCESSOR_RE.test(path);
}

export function cssPreprocessorOutputPath(file: string): string {
  return file.replace(/\.(?:scss|sass)$/, ".css");
}

export function cssPreprocessorProxyPath(file: string): string {
  return `${cssPreprocessorOutputPath(file)}.js`;
}

/** Sass compiler 를 app-first / fallback-second 로 require. 모듈 미설치 시 친화 메시지 throw. */
export function loadSassCompiler(root: string, fallbackRequire: NodeRequire): SassCompiler {
  return requireFromAppRoot(root, fallbackRequire, "sass") as SassCompiler;
}

/**
 * Sass 옵션 single source — full transform / dev fast-path / 어느 caller 가 부르
 * 든 같은 옵션 사용 보장. drift 회피용 helper.
 */
export function compileSassFile(
  sass: SassCompiler,
  file: string,
  loadRoot: string,
): SassCompileResult {
  return sass.compile(file, {
    style: "expanded",
    loadPaths: [dirname(file), loadRoot],
    sourceMap: false,
  });
}

const STYLE_REFERENCE_RE = /\.(?:html|mjs|cjs|js|jsx|ts|tsx)$/;

export function isStyleReferenceSource(path: string): boolean {
  return STYLE_REFERENCE_RE.test(path);
}

/**
 * HTML 은 `<link href=\"x.scss\">` 를 그대로 컴파일된 CSS 로, JS/TS 는 `.css.js`
 * proxy (`import \"./generated.css\"` 한 줄) 로 rewrite. CSS Modules 의 .module.css
 * rewriter 는 HTML 미지원이라 별도 함수 (rewriteCssModuleReferences).
 */
export function rewriteSassReferences(sourceFiles: readonly string[]): void {
  const pattern = /(["'])([^"']+\.(?:scss|sass))([?#][^"']*)?\1/g;
  for (const source of sourceFiles) {
    const input = readFileSync(source, "utf8");
    if (!input.includes(".scss") && !input.includes(".sass")) continue;
    // .html / .htm 모두 분기 (rewriteCssModuleReferences 와 일관 — case-insensitive).
    const toExt = /\.html?$/i.test(source) ? ".css" : ".css.js";
    const output = input.replace(
      pattern,
      (_match, quote, spec, suffix = "") =>
        `${quote}${spec.replace(/\.(?:scss|sass)$/, toExt)}${suffix}${quote}`,
    );
    if (output !== input) writeFileSync(source, output);
  }
}

/**
 * `cssPath` 의 basename 만 import 하는 한 줄 ESM proxy. bundler 가 module graph
 * 에서 CSS 를 side-effect 로 추적하기 위한 entry — 실제 CSS 는 build 시 chunk
 * 로 emit, dev 시 컴파일된 CSS 를 outdir 로 mirror 후 HTML `<link>` 로 서빙.
 */
export function buildCssPreprocessorProxy(cssPath: string): string {
  const cssImport = `./${basename(cssPath)}`;
  return `import ${JSON.stringify(cssImport)};\n`;
}

export interface TransformCssPreprocessorOptions {
  /** dirty Set — 그 안에 들어있는 파일만 재컴파일. null 이면 전체. */
  dirtyOnly?: ReadonlySet<string> | null;
  /** dirty source files — `rewriteSassReferences` 의 대상 한정. null 이면 sourceFiles 전체. */
  dirtySources?: readonly string[] | null;
}

/**
 * `files` (Sass/SCSS 입력) 를 컴파일해 같은 path 의 `.css` + `.css.js` proxy 생성.
 * `sourceFiles` (참조 HTML/JS/TS) 의 `import \"x.scss\"` 도 새 확장자로 rewrite.
 *
 * dirtyOnly 가 주어지면 그 안에 든 파일만 재컴파일하지만 반환 path 는 전체 (outdir
 * mirror 가 stale 안 되도록).
 */
export function transformCssPreprocessors(
  root: string,
  files: readonly string[],
  sourceFiles: readonly string[],
  logLevel: string | undefined,
  fallbackRequire: NodeRequire,
  options: TransformCssPreprocessorOptions = {},
): string[] {
  if (files.length === 0) return [];
  const { dirtyOnly = null, dirtySources = null } = options;
  const targets = dirtyOnly ? files.filter((f) => dirtyOnly.has(f)) : files;
  if (targets.length === 0) return files.map(cssPreprocessorOutputPath);

  let sass: SassCompiler;
  try {
    sass = loadSassCompiler(root, fallbackRequire);
  } catch (err) {
    const code = (err as NodeJS.ErrnoException)?.code;
    const message =
      code === "MODULE_NOT_FOUND" || code === "ERR_MODULE_NOT_FOUND"
        ? "Sass/SCSS support requires the optional `sass` package. Install it with `bun add -d sass` or `npm install -D sass`."
        : `Failed to load sass: ${(err as { message?: string })?.message ?? err}`;
    throw new Error(message);
  }

  for (const file of targets) {
    const result = compileSassFile(sass, file, root);
    const cssPath = cssPreprocessorOutputPath(file);
    writeFileSync(cssPath, result.css);
    writeFileSync(cssPreprocessorProxyPath(file), buildCssPreprocessorProxy(cssPath));
  }

  rewriteSassReferences(dirtySources ?? sourceFiles);
  if (logLevel !== "silent") {
    console.error(`[sass] processed ${targets.length} Sass/SCSS file(s)`);
  }
  return files.map(cssPreprocessorOutputPath);
}
