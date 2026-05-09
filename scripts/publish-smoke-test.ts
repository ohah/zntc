/**
 * Publish smoke test — 각 publishable workspace package 마다 publish tarball 을
 * 만들고 검증한다. publish 후 사용자 install 시 발생할 사고를 사전 차단:
 *
 * - workspace:* 가 concrete semver 로 변환됐는지
 * - private package (@zntc/server) 가 published dependencies 에 새지 않았는지
 * - 자기 자신을 dependencies 에 박아 install loop 유발하지 않는지
 * - peerDependencies 와 peerDependenciesMeta 가 일관 (선언만 하고 meta 누락)
 * - package.json 의 `main` / `types` / `bin` / `exports[*]` 가 가리키는 파일이
 *   실제로 tarball 안에 존재하는지
 * - `files` 화이트리스트로 sensitive 파일 (.env, *.test.*, node_modules 등) 누수 없음
 *
 * TARGETS 는 root package.json 의 `workspaces` 에서 자동 검출 — drift 차단.
 *
 * 사용:
 *   bun scripts/publish-smoke-test.ts
 *
 * 사전 조건: 각 패키지가 빌드된 상태 (`dist/`). CI 에서는 publish-smoke job 이
 * build step 선행.
 */

import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { mkdir, readFile, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '..');

const PRIVATE_PACKAGES = new Set(['@zntc/server']);

// `source` condition 은 monorepo internal-only — published tarball 에 src 가
// 들어가지 않는 게 정상 (외부 사용자는 dist 만 사용). parcel/microbundle 패턴.
const IGNORED_CONDITIONS = new Set(['source']);

// publish tarball 에 절대 들어가서는 안 되는 파일 패턴.
// `.gitkeep` 은 빈 디렉토리 보존용이라 무해 — 명시 화이트리스트로 제외.
const SUSPECT_PATTERNS: RegExp[] = [
  /(^|\/)\.env$/,
  /(^|\/)\.env\./,
  /\.test\./,
  /\.spec\./,
  /\.tsbuildinfo$/,
  /(^|\/)\.git\//,
  /(^|\/)\.gitignore$/,
  /(^|\/)\.gitattributes$/,
  /(^|\/)\.DS_Store$/,
  /\.log$/,
  /(^|\/)node_modules\//,
];

interface Failure {
  pkg: string;
  msg: string;
}

const failures: Failure[] = [];

function fail(pkg: string, msg: string) {
  failures.push({ pkg, msg });
  console.error(`  ❌ ${msg}`);
}

function ok(msg: string) {
  console.log(`  ✓ ${msg}`);
}

async function listFilesRecursive(root: string): Promise<string[]> {
  const out: string[] = [];
  async function walk(dir: string, prefix: string) {
    const entries = await readdir(dir, { withFileTypes: true });
    for (const e of entries) {
      const full = join(dir, e.name);
      const rel = prefix ? `${prefix}/${e.name}` : e.name;
      if (e.isDirectory()) await walk(full, rel);
      else out.push(rel);
    }
  }
  await walk(root, '');
  return out;
}

function normalizePath(p: string): string {
  return p.startsWith('./') ? p.slice(2) : p;
}

function collectExportsPaths(exportsField: unknown, out: Set<string>) {
  if (typeof exportsField === 'string') {
    out.add(normalizePath(exportsField));
    return;
  }
  if (exportsField && typeof exportsField === 'object') {
    for (const [key, v] of Object.entries(exportsField as Record<string, unknown>)) {
      if (IGNORED_CONDITIONS.has(key)) continue;
      collectExportsPaths(v, out);
    }
  }
}

function collectBinPaths(binField: unknown, out: Set<string>) {
  if (typeof binField === 'string') {
    out.add(normalizePath(binField));
    return;
  }
  if (binField && typeof binField === 'object') {
    for (const v of Object.values(binField as Record<string, unknown>)) {
      if (typeof v === 'string') out.add(normalizePath(v));
    }
  }
}

async function smokeOne(pkgDir: string, tmpRoot: string): Promise<void> {
  const absPkg = resolve(repoRoot, pkgDir);
  const sourcePkgJson = JSON.parse(await readFile(join(absPkg, 'package.json'), 'utf8'));
  const pkgName = sourcePkgJson.name as string;
  console.log(`\n=== ${pkgName} (${pkgDir}) ===`);

  // bun pm pack --quiet 는 stdout 에 tarball 파일명만 출력 — fragile name 추론 회피.
  const packDest = join(tmpRoot, encodeURIComponent(pkgName));
  await mkdir(packDest, { recursive: true });
  const packResult = spawnSync('bun', ['pm', 'pack', '--quiet', '--destination', packDest], {
    cwd: absPkg,
    encoding: 'utf8',
  });
  if (packResult.status !== 0) {
    fail(pkgName, `bun pm pack 실패: ${packResult.stderr || packResult.stdout}`);
    return;
  }
  // bun pm pack --quiet 는 절대 경로 또는 파일명을 stdout 에 출력 (버전마다 다름).
  const stdoutLine = packResult.stdout.trim().split(/\s+/).pop();
  if (!stdoutLine) {
    fail(pkgName, `bun pm pack stdout 에서 tarball 이름 못 찾음`);
    return;
  }
  const tarball = isAbsolute(stdoutLine) ? stdoutLine : join(packDest, basename(stdoutLine));
  if (!existsSync(tarball)) {
    fail(pkgName, `tarball 을 못 찾음: ${tarball}`);
    return;
  }

  const extractDir = join(packDest, 'extract');
  await mkdir(extractDir, { recursive: true });
  const tarResult = spawnSync('tar', ['-xzf', tarball, '-C', extractDir], { encoding: 'utf8' });
  if (tarResult.status !== 0) {
    fail(pkgName, `tar 추출 실패: ${tarResult.stderr}`);
    return;
  }

  const pkgRoot = join(extractDir, 'package');
  const tarballPkgJson = JSON.parse(await readFile(join(pkgRoot, 'package.json'), 'utf8'));
  const tarballFiles = await listFilesRecursive(pkgRoot);
  const fileSet = new Set(tarballFiles);

  // 1) workspace:* 잔존 없음
  const checkDeps = (deps: Record<string, string> | undefined, label: string) => {
    if (!deps) return;
    for (const [name, version] of Object.entries(deps)) {
      if (version.startsWith('workspace:')) {
        fail(pkgName, `${label}["${name}"] = "${version}" — workspace: prefix 잔존 (publish 변환 실패)`);
      }
    }
  };
  checkDeps(tarballPkgJson.dependencies, 'dependencies');
  checkDeps(tarballPkgJson.peerDependencies, 'peerDependencies');
  checkDeps(tarballPkgJson.optionalDependencies, 'optionalDependencies');

  // 2) private package 가 dependencies 에 누수되지 않음
  if (tarballPkgJson.dependencies) {
    for (const dep of Object.keys(tarballPkgJson.dependencies)) {
      if (PRIVATE_PACKAGES.has(dep)) {
        fail(pkgName, `dependencies."${dep}" 가 private — npm install 시 404`);
      }
      // 3) self-reference (install loop)
      if (dep === pkgName) {
        fail(pkgName, `dependencies."${dep}" 가 자기 자신 — npm install 시 무한 loop`);
      }
    }
  }

  // 4) peerDependencies / peerDependenciesMeta 일관
  const peerDeps = tarballPkgJson.peerDependencies as Record<string, string> | undefined;
  const peerMeta = tarballPkgJson.peerDependenciesMeta as Record<string, unknown> | undefined;
  if (peerMeta) {
    for (const metaKey of Object.keys(peerMeta)) {
      if (!peerDeps || !(metaKey in peerDeps)) {
        fail(pkgName, `peerDependenciesMeta."${metaKey}" 가 peerDependencies 에 없음`);
      }
    }
  }

  // 5) main / types / bin / exports paths 가 tarball 안에 존재
  const checkPath = (rel: string, label: string) => {
    if (!fileSet.has(rel)) fail(pkgName, `${label} = "${rel}" — tarball 에 없음`);
  };
  if (tarballPkgJson.main) checkPath(normalizePath(tarballPkgJson.main), 'main');
  if (tarballPkgJson.types) checkPath(normalizePath(tarballPkgJson.types), 'types');

  if (tarballPkgJson.bin) {
    const binPaths = new Set<string>();
    collectBinPaths(tarballPkgJson.bin, binPaths);
    for (const p of binPaths) checkPath(p, `bin "${p}"`);
  }

  if (tarballPkgJson.exports) {
    const paths = new Set<string>();
    collectExportsPaths(tarballPkgJson.exports, paths);
    for (const p of paths) checkPath(p, `exports "${p}"`);
    if (paths.size > 0) ok(`exports paths ${paths.size}개 모두 존재`);
  }

  // 6) sensitive 파일 누수 검사
  for (const f of tarballFiles) {
    for (const p of SUSPECT_PATTERNS) {
      if (p.test(f)) {
        fail(pkgName, `의심 파일 누수: ${f} (files 화이트리스트 점검 필요)`);
      }
    }
  }
  ok(`tarball 파일 ${tarballFiles.length}개`);
}

async function detectTargets(): Promise<string[]> {
  // root package.json 의 workspaces 에서 packages/* 만 추출. examples/tests/documents
  // 같은 비-publish 워크스페이스 제외.
  const root = JSON.parse(await readFile(join(repoRoot, 'package.json'), 'utf8'));
  const ws = root.workspaces as string[] | undefined;
  if (!ws) throw new Error('root package.json 에 workspaces 필드 없음');
  return ws
    .map((w) => w.replace(/^\.\//, ''))
    .filter((w) => w.startsWith('packages/'));
}

async function main() {
  const targets = await detectTargets();
  console.log(`Detected ${targets.length} workspace packages:`, targets.join(', '));

  const tmpRoot = mkdtempSync(join(tmpdir(), 'zntc-publish-smoke-'));
  try {
    for (const t of targets) {
      const pkgJsonPath = resolve(repoRoot, t, 'package.json');
      if (!existsSync(pkgJsonPath)) {
        console.warn(`skip: ${t} (package.json 없음)`);
        continue;
      }
      const pkg = JSON.parse(await readFile(pkgJsonPath, 'utf8'));
      if (pkg.private) {
        console.log(`\nskip: ${pkg.name} (private)`);
        continue;
      }
      const distDir = resolve(repoRoot, t, 'dist');
      if (!existsSync(distDir)) {
        console.log(`\n=== ${pkg.name} (${t}) ===`);
        fail(pkg.name, `dist/ 없음 — 빌드 선행 필요 (bun run --cwd ${t} build)`);
        continue;
      }
      try {
        await smokeOne(t, tmpRoot);
      } catch (e) {
        fail(pkg.name, `예외: ${(e as Error).message}`);
      }
    }
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }

  console.log('\n────────────────');
  if (failures.length === 0) {
    console.log(`✓ 모든 검사 통과`);
    return;
  }
  console.error(`❌ ${failures.length}건 실패:`);
  for (const f of failures) console.error(`  - ${f.pkg}: ${f.msg}`);
  process.exit(1);
}

await main();
