// GET /assets/* + /node_modules/* — Metro 호환 asset registry. RN runtime 의
// `require('./icon.png')` 가 dev server 의 /assets/icon.png 로 요청. scale
// variant (`@2x.png` → `.png`) 제거 후 projectRoot + nodeModulesPaths 에서
// 다단계 strategy 로 resolve (hoisted / scoped / pnpm / bun / non-hoisted /
// monorepo / require.resolve fallback).

import { existsSync, lstatSync, readdirSync, realpathSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { dirname, extname, resolve, sep } from 'node:path';

import { sendText } from '../http-utils.ts';

export function isAssetRoute(pathname: string): boolean {
  return pathname.startsWith('/assets/') || pathname.startsWith('/node_modules/');
}

export interface AssetResolverOptions {
  projectRoot: string;
  nodeModulesPaths: readonly string[];
}

const CONTENT_TYPE_MAP: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.bmp': 'image/bmp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.json': 'application/json',
};

/**
 * symlink 재귀 resolve. Bun 의 .bun 디렉토리 / pnpm 가 사용 — recursion depth
 * 가드로 cycle 방지.
 */
function resolveSymlink(path: string, maxDepth = 10): string {
  if (maxDepth <= 0) return path;
  try {
    if (existsSync(path)) {
      const stats = lstatSync(path);
      if (stats.isSymbolicLink()) {
        return resolveSymlink(realpathSync(path), maxDepth - 1);
      }
    }
  } catch {
    /* ignore */
  }
  return path;
}

function sanitizeRelativePath(input: string): string {
  const segments = input.split('/');
  const out: string[] = [];
  for (const seg of segments) {
    if (seg === '..') {
      if (out.length > 0) out.pop();
    } else if (seg !== '.' && seg !== '') {
      out.push(seg);
    }
  }
  return out.join('/');
}

/**
 * Metro 호환 multi-strategy resolution. node_modules 경로 안 패키지는
 * hoisted/scoped/pnpm/bun/non-hoisted/monorepo/require.resolve 7단계로 시도.
 */
export function resolveAssetPath(urlPathname: string, opts: AssetResolverOptions): string | null {
  let assetRelativePath: string;
  if (urlPathname.startsWith('/assets/')) {
    assetRelativePath = sanitizeRelativePath(urlPathname.slice('/assets/'.length));
  } else if (urlPathname.startsWith('/node_modules/')) {
    assetRelativePath = `node_modules/${urlPathname.slice('/node_modules/'.length)}`;
  } else {
    return null;
  }

  // RN bundler 가 `@2x` / `@3x` scale suffix 를 붙인 요청 — 실제 파일은 base
  // 이름. (`icon@2x.png` → `icon.png`)
  assetRelativePath = assetRelativePath.replace(/@\d+x\./, '.');
  assetRelativePath = assetRelativePath.replace(/\\/g, '/');
  const normalizedPath = assetRelativePath.replace(/\//g, sep);

  let resolved = resolve(opts.projectRoot, normalizedPath);

  if (existsSync(resolved)) return resolveSymlink(resolved);

  // monorepo node_modules path — `../node_modules/...` 형태
  for (const nmPath of opts.nodeModulesPaths) {
    const monorepoRoot = resolve(opts.projectRoot, nmPath);
    const candidate = resolve(monorepoRoot, '..', normalizedPath);
    if (existsSync(candidate)) return resolveSymlink(candidate);
  }

  // node_modules/[.pnpm|.bun/<dir>/node_modules/]<package>/<rest>
  const nmMatch = normalizedPath.match(
    /node_modules[/\\](?:\.(?:pnpm|bun)[/\\]([^/\\]+)[/\\]node_modules[/\\])?([^/\\]+)[/\\](.+)$/,
  );
  if (!nmMatch) return null;

  const bunPackageDir = nmMatch[1];
  let packageNameOrPath = nmMatch[2];
  let restPath = nmMatch[3];
  if (!packageNameOrPath || !restPath) return null;

  // Scoped package: regex 의 `[^/\\]+` 가 first segment 만 잡으므로 `@scope` 가 들어오면
  // restPath 의 first segment (`pkg`) 와 결합해 `@scope/pkg` 로 재구성. 이후 모든 strategy
  // 가 scoped package 를 정확히 매칭.
  if (packageNameOrPath.startsWith('@')) {
    const slashIdx = restPath.indexOf(sep);
    if (slashIdx > 0) {
      packageNameOrPath = `${packageNameOrPath}/${restPath.slice(0, slashIdx)}`;
      restPath = restPath.slice(slashIdx + 1);
    }
  }

  // Strategy 1: hoisted (npm/yarn standard) — node_modules/<package>/<rest>
  if (!bunPackageDir && !packageNameOrPath.includes('@')) {
    const candidate = resolve(opts.projectRoot, 'node_modules', packageNameOrPath, restPath);
    if (existsSync(candidate)) return resolveSymlink(candidate);
  }

  // Strategy 2: scoped hoisted — node_modules/@scope/package/<rest>
  if (packageNameOrPath.startsWith('@')) {
    const candidate = resolve(opts.projectRoot, 'node_modules', packageNameOrPath, restPath);
    if (existsSync(candidate)) return resolveSymlink(candidate);
  }

  // Strategy 3: pnpm — node_modules/.pnpm/<package@version>/node_modules/<package>/<rest>
  const pnpmDir = resolve(opts.projectRoot, 'node_modules', '.pnpm');
  if (existsSync(pnpmDir)) {
    try {
      const entries = readdirSync(pnpmDir);
      const pnpmPkgName = packageNameOrPath.startsWith('@')
        ? packageNameOrPath.replace('/', '+')
        : packageNameOrPath;
      for (const entry of entries) {
        if (entry.startsWith(`${pnpmPkgName}@`) || entry === pnpmPkgName) {
          const candidate = resolve(pnpmDir, entry, 'node_modules', packageNameOrPath, restPath);
          if (existsSync(candidate)) return resolveSymlink(candidate);
        }
      }
    } catch {
      /* ignore */
    }
  }

  // Strategy 4: Bun .bun/<package@version+hash>/node_modules/<package>/<rest>
  const bunDirCandidates = [
    resolve(opts.projectRoot, 'node_modules', '.bun'),
    ...opts.nodeModulesPaths.map((p) => resolve(opts.projectRoot, p, '.bun')),
  ];
  for (const bunDir of bunDirCandidates) {
    if (!existsSync(bunDir)) continue;
    try {
      if (bunPackageDir) {
        const dir = resolveSymlink(resolve(bunDir, bunPackageDir));
        const candidate = resolve(dir, 'node_modules', packageNameOrPath, restPath);
        if (existsSync(candidate)) return resolveSymlink(candidate);
      } else {
        const bunPkgName = packageNameOrPath.startsWith('@')
          ? packageNameOrPath.replace('/', '+')
          : packageNameOrPath;
        for (const entry of readdirSync(bunDir)) {
          if (entry.startsWith(`${bunPkgName}@`) || entry === bunPkgName) {
            const dir = resolveSymlink(resolve(bunDir, entry));
            const candidate = resolve(dir, 'node_modules', packageNameOrPath, restPath);
            if (existsSync(candidate)) return resolveSymlink(candidate);
          }
        }
      }
    } catch {
      /* ignore */
    }
  }

  // Strategy 5: non-hoisted nested — node_modules/<a>/node_modules/<b>/<rest>
  const nonHoisted = resolve(
    opts.projectRoot,
    'node_modules',
    packageNameOrPath,
    'node_modules',
    restPath,
  );
  if (existsSync(nonHoisted)) return resolveSymlink(nonHoisted);

  // Strategy 6: monorepo node_modules paths
  for (const nmPath of opts.nodeModulesPaths) {
    const candidate = resolve(opts.projectRoot, nmPath, packageNameOrPath, restPath);
    if (existsSync(candidate)) return resolveSymlink(candidate);
  }

  // Strategy 7: require.resolve(<package>/package.json) → packageDir + restPath
  if (normalizedPath.startsWith('node_modules')) {
    try {
      const modulePath = normalizedPath.replace(/^node_modules[/\\]/, '');
      const packageName = modulePath.startsWith('@')
        ? (modulePath.match(/^(@[^/\\]+[/\\][^/\\]+)/)?.[1] ?? modulePath.split(sep)[0])
        : modulePath.split(sep)[0];
      if (!packageName) return null;
      const packageRelativePath = modulePath.slice(packageName.length + 1);

      let packageJsonPath: string;
      try {
        packageJsonPath = require.resolve(`${packageName}/package.json`, {
          paths: [opts.projectRoot, ...opts.nodeModulesPaths],
        });
      } catch {
        const candidates = [
          resolve(opts.projectRoot, 'node_modules', packageName, 'package.json'),
          ...opts.nodeModulesPaths.map((p) =>
            resolve(opts.projectRoot, p, packageName, 'package.json'),
          ),
        ];
        const found = candidates.find((c) => existsSync(c));
        if (!found) return null;
        packageJsonPath = found;
      }
      const candidate = resolve(dirname(packageJsonPath), packageRelativePath);
      if (existsSync(candidate)) return resolveSymlink(candidate);
    } catch {
      /* ignore */
    }
  }

  return null;
}

function isWithinRoot(path: string, root: string): boolean {
  // `/foo` vs `/foo-bar` prefix attack 방어 — sep 결합 또는 정확히 root 자체.
  if (path === root) return true;
  return path.startsWith(root + sep);
}

function isAllowedPath(path: string, opts: AssetResolverOptions): boolean {
  const normalized = resolve(path);
  if (isWithinRoot(normalized, resolve(opts.projectRoot))) return true;
  return opts.nodeModulesPaths.some((p) => isWithinRoot(normalized, resolve(opts.projectRoot, p)));
}

export async function handleAssetRequest(
  _req: IncomingMessage,
  res: ServerResponse,
  url: URL,
  opts: AssetResolverOptions,
): Promise<void> {
  try {
    const resolved = resolveAssetPath(url.pathname, opts);
    if (!resolved) {
      sendText(res, 404, 'Not Found');
      return;
    }
    if (!isAllowedPath(resolved, opts)) {
      sendText(res, 403, 'Forbidden');
      return;
    }
    if (!existsSync(resolved)) {
      sendText(res, 404, 'Not Found');
      return;
    }

    const ext = extname(resolved).toLowerCase();
    const contentType = CONTENT_TYPE_MAP[ext] ?? 'application/octet-stream';
    const content = await readFile(resolved);
    res.writeHead(200, {
      'Content-Type': contentType,
      'Cache-Control': 'public, max-age=31536000',
      'Content-Length': content.length,
    });
    res.end(content);
  } catch {
    sendText(res, 500, 'Internal Server Error');
  }
}
