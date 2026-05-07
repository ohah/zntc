import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { basename, relative, sep } from 'node:path';

import {
  isCssIdent,
  isCssIdentStart,
  skipCssString,
  skipCssUrl,
  startsWithCssIdent,
} from './css-parser.ts';

/** `.module.css` 종결만 인식 — case-sensitive (Vite/webpack css-loader 컨벤션 일치). */
export function isCssModuleFile(path: string): boolean {
  return basename(path).endsWith('.module.css');
}

export function cssModuleGeneratedCssPath(file: string): string {
  return file.replace(/\.module\.css$/, '.module.zntc.css');
}

/**
 * `x.module.css → x.module.css.js` proxy. sass 의 `cssPreprocessorProxyPath`
 * (`x.scss → x.css.js`) 와 출력 형태가 다른 이유: CSS Modules 는 원본 확장자
 * 보존이 import resolver 에 필요 (`.module.css` 를 import 한 caller 의 type
 * 추론과 일치).
 */
export function cssModuleProxyPath(file: string): string {
  return `${file}.js`;
}

const SAFE_LOCAL_RE = /[^a-zA-Z0-9_]/g;

/**
 * `${fileName}_${safeLocal}__${hash8}` 형식의 unique class name.
 * hash 8 chars (~48 bits) 면 100k 클래스에서도 birthday collision <0.001%.
 */
export function cssModuleLocalName(root: string, file: string, local: string): string {
  const rel = relative(root, file).replaceAll(sep, '/');
  const fileName = basename(file, '.module.css').replace(SAFE_LOCAL_RE, '_');
  return cssModuleLocalNameWithCachedFile(rel, fileName, local);
}

/**
 * 같은 file 의 여러 class 처리 시 `rel` / `fileName` 을 한 번만 계산하도록 inner
 * helper. 100 class CSS 면 path/string 연산 99회 절약.
 */
function cssModuleLocalNameWithCachedFile(rel: string, fileName: string, local: string): string {
  const safeLocal = local.replace(SAFE_LOCAL_RE, '_');
  const hash = createHash('sha1').update(`${rel}:${local}`).digest('base64url').slice(0, 8);
  return `${fileName}_${safeLocal}__${hash}`;
}

export interface CssModuleClassToken {
  start: number;
  end: number;
  local: string;
}

/**
 * CSS 안의 일반 `.class-name` 토큰 위치를 수집. `:global`/`:local` 슈도, `composes:`
 * 룰, `@keyframes` 이름 scoping 등 고급 CSS Modules 스펙은 미지원.
 */
export function scanCssModuleClassTokens(css: string): CssModuleClassToken[] {
  const tokens: CssModuleClassToken[] = [];
  let i = 0;
  while (i < css.length) {
    const ch = css[i]!;
    const next = css[i + 1] ?? '';
    if ((ch === '"' || ch === "'") && css[i - 1] !== '\\') {
      i = skipCssString(css, i, ch);
      continue;
    }
    if (ch === '/' && next === '*') {
      const end = css.indexOf('*/', i + 2);
      i = end === -1 ? css.length : end + 2;
      continue;
    }
    if (startsWithCssIdent(css, i, 'url(')) {
      i = skipCssUrl(css, i + 4);
      continue;
    }
    if (ch === '.' && isCssIdentStart(next)) {
      let end = i + 2;
      while (end < css.length && isCssIdent(css[end]!)) end += 1;
      tokens.push({ start: i, end, local: css.slice(i + 1, end) });
      i = end;
      continue;
    }
    i += 1;
  }
  return tokens;
}

export function collectCssModuleClasses(css: string): string[] {
  return [...new Set(scanCssModuleClassTokens(css).map((token) => token.local))];
}

export function rewriteCssModuleClasses(css: string, mapping: Record<string, string>): string {
  return rewriteCssModuleClassesWithTokens(css, scanCssModuleClassTokens(css), mapping);
}

const VALID_EXPORT_NAME_RE = /^[$A-Z_a-z][$\w]*$/;

// ECMAScript ReservedWord + FutureReservedWord + strict-mode binding 제약 (`arguments`).
// `export const ${name}` 의 top-level binding 으로 SyntaxError 가 나는 모든 이름.
const CSS_MODULE_RESERVED_EXPORTS: ReadonlySet<string> = new Set([
  'arguments',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'debugger',
  'default',
  'delete',
  'do',
  'else',
  'enum',
  'export',
  'extends',
  'false',
  'finally',
  'for',
  'function',
  'if',
  'implements',
  'import',
  'in',
  'instanceof',
  'interface',
  'let',
  'new',
  'null',
  'package',
  'private',
  'protected',
  'public',
  'return',
  'static',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'typeof',
  'var',
  'void',
  'while',
  'with',
  'yield',
]);

export function isValidExportName(name: string): boolean {
  return VALID_EXPORT_NAME_RE.test(name) && !CSS_MODULE_RESERVED_EXPORTS.has(name);
}

/**
 * proxy module — class-name map 의 default export 와 valid identifier named
 * export 를 emit. 실제 CSS 는 generated `.module.zntc.css` 가 `<link>` 로 도달.
 */
export function buildCssModuleProxy(
  generatedCssPath: string,
  mapping: Record<string, string>,
): string {
  const cssImport = `./${basename(generatedCssPath)}`;
  const stylesJson = JSON.stringify(mapping);
  const named = Object.keys(mapping)
    .filter(isValidExportName)
    .map((name) => `export const ${name} = ${JSON.stringify(mapping[name])};`)
    .join('\n');
  return [
    `import ${JSON.stringify(cssImport)};`,
    `const styles = ${stylesJson};`,
    'export default styles;',
    named,
    '',
  ]
    .filter(Boolean)
    .join('\n');
}

/**
 * `import \"x.module.css\"` → `\"x.module.css.js\"` proxy redirect.
 * HTML 의 `<link href=\"x.module.css\">` 는 일반 CSS 로 취급되므로 skip.
 */
export function rewriteCssModuleReferences(sourceFiles: readonly string[]): void {
  const pattern = /(["'])([^"']+\.module\.css)([?#][^"']*)?\1/g;
  for (const source of sourceFiles) {
    if (/\.html?$/i.test(source)) continue;
    const input = readFileSync(source, 'utf8');
    if (!input.includes('.module.css')) continue;
    const output = input.replace(
      pattern,
      (_match, quote, spec, suffix = '') => `${quote}${spec}.js${suffix}${quote}`,
    );
    if (output !== input) writeFileSync(source, output);
  }
}

export interface TransformCssModulesOptions {
  /** dirty Set — 그 안에 들어있는 파일만 재처리. null 이면 전체. */
  dirtyOnly?: ReadonlySet<string> | null;
  /** dirty source files — `rewriteCssModuleReferences` 의 대상 한정. */
  dirtySources?: readonly string[] | null;
}

/**
 * `moduleFiles` 의 `.module.css` 를 generated `.module.zntc.css` + `.module.css.js`
 * proxy 로 변환. `styleSources` 의 `import \"x.module.css\"` 는 proxy 로 redirect.
 *
 * dirtyOnly 가 주어지면 그 안에 든 파일만 재처리하지만 반환은 전체 list —
 * incremental rebuild 시에도 caller 가 일관된 set 을 받도록.
 */
export function transformCssModules(
  root: string,
  moduleFiles: readonly string[],
  styleSources: readonly string[],
  logLevel: string | undefined,
  options: TransformCssModulesOptions = {},
): string[] {
  if (moduleFiles.length === 0) return [];
  const { dirtyOnly = null, dirtySources = null } = options;
  const targets = dirtyOnly ? moduleFiles.filter((f) => dirtyOnly.has(f)) : moduleFiles;
  if (targets.length === 0) return moduleFiles.map(cssModuleGeneratedCssPath);

  for (const file of targets) {
    const css = readFileSync(file, 'utf8');
    // 단일 scan 으로 token + mapping 동시 생성 — collect + rewrite 의 중복 scan 회피.
    const tokens = scanCssModuleClassTokens(css);
    const rel = relative(root, file).replaceAll(sep, '/');
    const fileName = basename(file, '.module.css').replace(SAFE_LOCAL_RE, '_');
    const mapping: Record<string, string> = {};
    for (const token of tokens) {
      if (!mapping[token.local]) {
        mapping[token.local] = cssModuleLocalNameWithCachedFile(rel, fileName, token.local);
      }
    }
    const rewrittenCss = rewriteCssModuleClassesWithTokens(css, tokens, mapping);
    const generatedCssPath = cssModuleGeneratedCssPath(file);
    writeFileSync(generatedCssPath, rewrittenCss);
    writeFileSync(cssModuleProxyPath(file), buildCssModuleProxy(generatedCssPath, mapping));
  }

  rewriteCssModuleReferences(dirtySources ?? styleSources);

  if (logLevel !== 'silent') {
    console.error(`[css-modules] processed ${targets.length} CSS module file(s)`);
  }
  return moduleFiles.map(cssModuleGeneratedCssPath);
}

/**
 * `rewriteCssModuleClasses` 의 inner — 미리 scan 한 token 재사용. transformCssModules
 * 의 단일 scan 경로에 사용.
 */
function rewriteCssModuleClassesWithTokens(
  css: string,
  tokens: readonly CssModuleClassToken[],
  mapping: Record<string, string>,
): string {
  let out = '';
  let offset = 0;
  for (const token of tokens) {
    const scoped = mapping[token.local];
    if (!scoped) continue;
    out += css.slice(offset, token.start);
    out += `.${scoped}`;
    offset = token.end;
  }
  out += css.slice(offset);
  return out;
}
