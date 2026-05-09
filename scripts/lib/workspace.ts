/**
 * 4 publish 관련 script (publish-smoke / publish-install / publint-all /
 * publishable-deps-check) 의 공통 helper. workspace 검출 + tarball pack 의
 * drift 차단.
 */

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
export const repoRoot: string = resolve(__dirname, '..', '..');

export interface PackageInfo {
  /** workspace 상대 path (예: "packages/core") */
  dir: string;
  /** 절대 path */
  absDir: string;
  /** package.json name */
  name: string;
  /** package.json 전체 */
  pkg: any;
  /** private: true 인지 */
  isPrivate: boolean;
  /** dist/ 디렉토리 존재 여부 */
  hasDist: boolean;
}

/**
 * root package.json 의 workspaces 에서 packages/* 만 추출 + package.json 파싱.
 * examples / tests / documents 같은 비-publish workspace 는 제외.
 */
export async function detectWorkspacePackages(): Promise<PackageInfo[]> {
  const root = JSON.parse(await readFile(join(repoRoot, 'package.json'), 'utf8'));
  const ws = (root.workspaces as string[] | undefined) ?? [];
  const out: PackageInfo[] = [];
  for (const raw of ws) {
    const dir = raw.replace(/^\.\//, '');
    if (!dir.startsWith('packages/')) continue;
    const absDir = resolve(repoRoot, dir);
    const pkgJsonPath = join(absDir, 'package.json');
    if (!existsSync(pkgJsonPath)) continue;
    const pkg = JSON.parse(await readFile(pkgJsonPath, 'utf8'));
    out.push({
      dir,
      absDir,
      name: pkg.name as string,
      pkg,
      isPrivate: pkg.private === true,
      hasDist: existsSync(join(absDir, 'dist')),
    });
  }
  return out;
}

/**
 * `bun pm pack --quiet --destination <dest>` 호출 + tarball 절대 경로 반환.
 * stdout 의 절대/상대 path 모두 normalize.
 */
export function packTarball(pkgDir: string, destDir: string): string | null {
  const res = spawnSync('bun', ['pm', 'pack', '--quiet', '--destination', destDir], {
    cwd: pkgDir,
    encoding: 'utf8',
  });
  if (res.status !== 0) return null;
  const line = res.stdout.trim().split(/\s+/).pop();
  if (!line) return null;
  const tarball = isAbsolute(line) ? line : join(destDir, basename(line));
  return existsSync(tarball) ? tarball : null;
}
