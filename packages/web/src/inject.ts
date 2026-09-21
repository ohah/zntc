import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { basename, join, sep } from 'node:path';

import { APP_DEV_HMR_CLIENT_PATH, APP_DEV_REACT_REFRESH_PATH } from '@zntc/server';

import { isCssFile } from './style/postcss.ts';
import { joinUrl } from './url.ts';

interface BundleOutputFile {
  path?: string;
}

export interface BundleResult {
  outputFiles?: readonly BundleOutputFile[];
}

/**
 * `<outdir>/index.html` 을 읽어 `build(html)` 결과 (`<head>` 직전 / `<script>`
 * 직전 삽입할 tag string) 를 끼워 넣는다. ENOENT 면 silent skip — dev mode 에서
 * 아직 entry HTML 이 없을 수 있음.
 */
export function injectIntoDevHtml(outdir: string, build: (html: string) => string | null): void {
  const htmlPath = join(outdir, 'index.html');
  let html: string;
  try {
    html = readFileSync(htmlPath, 'utf8');
  } catch (err) {
    if ((err as NodeJS.ErrnoException)?.code === 'ENOENT') return;
    throw err;
  }
  const tag = build(html);
  if (!tag) return;
  const next = html.includes('</head>')
    ? html.replace('</head>', `${tag}\n</head>`)
    : html.replace('<script', `${tag}\n<script`);
  writeFileSync(htmlPath, next);
}

/**
 * (#4671) 우리가 주입한 `<link rel="stylesheet">` 임을 표시하는 속성.
 *
 * 사용자가 `index.html` 에 손으로 적은 링크와 구분해야 한다 — 구분 없이 정리하면
 * 사용자 링크까지 지운다.
 */
export const ZNTC_CSS_LINK_ATTR = 'data-zntc-css';

/** 주입용 `<link>` 태그 한 줄. 마커가 붙는 지점을 한 곳으로 모은다. */
function cssLinkTag(href: string): string {
  return `<link rel="stylesheet" href="${href}" ${ZNTC_CSS_LINK_ATTR}>`;
}

/**
 * (#4671) 우리가 주입한 CSS 링크 중 `keepHrefs` 에 없는 것을 지운다.
 *
 * 주입기는 추가만 하고 지우지 않았다. 그래서 JS 에서 `import './a.css'` 를 **지워도**
 * 링크가 남아 스타일이 계속 적용됐다. outdir 의 **파일** 정리는 `reconcileOutdir` 가
 * 맡는데 HTML 의 **링크** 를 맞추는 짝이 없었다.
 *
 * 마커가 붙은 링크만 대상이다 — 사용자가 직접 적은 링크는 건드리지 않는다.
 * href 의 쿼리(`?t=…` 캐시버스트)는 떼고 비교한다.
 */
export function pruneAppDevCssLinks(outdir: string, keepHrefs: ReadonlySet<string>): void {
  const htmlPath = join(outdir, 'index.html');
  let html: string;
  try {
    html = readFileSync(htmlPath, 'utf8');
  } catch (err) {
    if ((err as NodeJS.ErrnoException)?.code === 'ENOENT') return;
    throw err;
  }
  const pattern = new RegExp(`\\n?<link[^>]*${ZNTC_CSS_LINK_ATTR}[^>]*>`, 'g');
  const next = html.replace(pattern, (tag) => {
    const href = /href="([^"]*)"/.exec(tag)?.[1];
    if (!href) return tag;
    const bare = href.split('?')[0] ?? href;
    return keepHrefs.has(bare) ? tag : '';
  });
  if (next !== html) writeFileSync(htmlPath, next);
}

/** `<script type="module" src="/__zntc_app_dev_hmr__"></script>` 를 head 에 1회 삽입. */
export function injectAppDevHmrClient(outdir: string): void {
  injectIntoDevHtml(outdir, (html) => {
    if (html.includes(APP_DEV_HMR_CLIENT_PATH)) return null;
    return `<script type="module" src="${APP_DEV_HMR_CLIENT_PATH}"></script>`;
  });
}

/**
 * React Fast Refresh preamble `<script src="/__zntc_react_refresh__"></script>` 를 1회 삽입.
 * ⚠️ **첫 `<script` 앞**에 넣는다 — classic(non-module) 스크립트라 파싱 중 동기 실행되어
 * `injectIntoGlobalHook(window)` 가 React 를 import 하는 (deferred) module 스크립트보다 *먼저*
 * 끝나야 reconciler 패치가 유효하다. injectIntoDevHtml(=`</head>` 앞 삽입)을 안 쓰는 이유.
 */
export function injectAppDevReactRefreshPreamble(outdir: string): void {
  const htmlPath = join(outdir, 'index.html');
  let html: string;
  try {
    html = readFileSync(htmlPath, 'utf8');
  } catch (err) {
    if ((err as NodeJS.ErrnoException)?.code === 'ENOENT') return;
    throw err;
  }
  if (html.includes(APP_DEV_REACT_REFRESH_PATH)) return; // 멱등
  const tag = `<script src="${APP_DEV_REACT_REFRESH_PATH}"></script>`;
  // <head> 여는 태그 *바로 뒤*(head 의 첫 자식)에 넣어 head 안 어떤 script 보다도 먼저
  // 동기 실행되게 한다. 주석/텍스트 안의 `<script` 문자열에 잘못 매칭하지 않도록
  // 단순 replace('<script') 대신 <head> 위치를 명시적으로 찾는다.
  const headOpen = html.match(/<head\b[^>]*>/i);
  let next: string;
  if (headOpen && headOpen.index !== undefined) {
    const at = headOpen.index + headOpen[0].length;
    next = `${html.slice(0, at)}\n${tag}${html.slice(at)}`;
  } else if (html.includes('</head>')) {
    next = html.replace('</head>', `${tag}\n</head>`);
  } else if (html.includes('<script')) {
    next = html.replace('<script', `${tag}\n<script`);
  } else {
    next = `${tag}\n${html}`;
  }
  writeFileSync(htmlPath, next);
}

export function injectAppDevBundleCssLinks(
  outdir: string,
  base: string | undefined,
  bundleResult: BundleResult | null | undefined,
): void {
  injectIntoDevHtml(outdir, (html) => {
    const cssHrefs: string[] = [];
    for (const file of bundleResult?.outputFiles ?? []) {
      if (!file?.path || !isCssFile(file.path)) continue;
      const href = joinUrl(base, basename(file.path));
      if (!html.includes(`href="${href}"`) && !html.includes(`href='${href}'`)) cssHrefs.push(href);
    }
    if (cssHrefs.length === 0) return null;
    return cssHrefs.map(cssLinkTag).join('\n');
  });
}

/**
 * #3813 — outdir 의 `.css` 파일을 file system 스캔해 HTML `<link>` 주입. `injectAppDevBundleCssLinks`
 * 가 `bundleResult.outputFiles` 를 받는 것과 달리 file system 기반. caller (`runServe`) 가
 * native watch onRebuild 에서 호출 — bundleResult 가 없는 graphChanged 경로의 stale link 회귀
 * 가드. outdir 의 first-level `*.css` 만 스캔 (chunk subdirectory 미포함 — bundler 의 entry_names
 * `[dir]/[name]` default 가 emit 한 결과 위치 기준).
 */
export function injectAppDevBundleCssLinksFromOutdir(
  outdir: string,
  base: string | undefined,
): void {
  injectIntoDevHtml(outdir, (html) => {
    let entries: string[];
    try {
      entries = readdirSync(outdir);
    } catch {
      return null;
    }
    const cssHrefs: string[] = [];
    for (const name of entries) {
      if (!isCssFile(name)) continue;
      const href = joinUrl(base, name);
      if (!html.includes(`href="${href}"`) && !html.includes(`href='${href}'`)) cssHrefs.push(href);
    }
    if (cssHrefs.length === 0) return null;
    return cssHrefs.map(cssLinkTag).join('\n');
  });
}

export function injectAppDevPipelineCssLinks(
  outdir: string,
  base: string | undefined,
  cssRelPaths: readonly string[],
): void {
  if (cssRelPaths.length === 0) return;
  injectIntoDevHtml(outdir, (html) => {
    const tags: string[] = [];
    for (const rel of cssRelPaths) {
      const href = joinUrl(base, rel.replaceAll(sep, '/'));
      if (html.includes(`href="${href}"`) || html.includes(`href='${href}'`)) continue;
      tags.push(cssLinkTag(href));
    }
    return tags.length === 0 ? null : tags.join('\n');
  });
}
