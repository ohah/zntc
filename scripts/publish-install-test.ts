/**
 * Publish install test — 각 publishable workspace package 의 tarball 을
 * fresh dir 에 실제 install 시도. publish-smoke (tarball layout) 가 잡지 못하는
 * 사고를 cover:
 *
 * - dependency resolution 실제로 동작하는지 (workspace:* 변환 후 link 가능?)
 * - bin / main / types 가 install dir 에 정확히 풀리는지
 * - peer/optional dependency 누락 시 install 자체는 통과해야 (선택적)
 * - cross-package install (web → core) 가 file: link 로 자가 monorepo 에서 동작
 *
 * 전략: workspace 의 publishable package 마다
 *   1. bun pm pack 으로 tarball 생성
 *   2. tmp dir 에 npm init -y
 *   3. 자기 + transitive workspace dep tarball 들을 file: 로 동시 install
 *   4. require.resolve("<pkgName>") 로 entry 해결 가능 검증
 *
 * import 호출 시 NAPI binary / WASM / RN runtime 등 환경 의존 module 이 missing
 * 으로 fail 가능 — 본 script 는 layout / resolution 만 검증. 깊이 import 는
 * 별도 jobs (NAPI/WASM/RN) 가 담당.
 *
 * 사용:
 *   bun scripts/publish-install-test.ts
 */

import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { detectWorkspacePackages, packTarball } from './lib/workspace.ts';

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

interface TargetInfo {
  dir: string;
  name: string;
  tarballPath: string;
  workspaceDeps: string[];
}

function collectWorkspaceDeps(pkg: any, allNames: Set<string>): string[] {
  const result: string[] = [];
  const collectFrom = (deps: Record<string, string> | undefined) => {
    if (!deps) return;
    for (const [name, version] of Object.entries(deps)) {
      if (version.startsWith('workspace:') && allNames.has(name)) {
        result.push(name);
      }
    }
  };
  // dependencies 만 — devDeps 는 install 시 안 따라감 (production install)
  collectFrom(pkg.dependencies);
  return result;
}

async function detectTargets(tmpRoot: string): Promise<TargetInfo[]> {
  const all = await detectWorkspacePackages();

  // publishable 만 + dist 존재 검증
  const targets: TargetInfo[] = [];
  const allNames = new Set<string>();
  const pkgInfos: { dir: string; pkg: any }[] = [];
  for (const t of all) {
    if (t.isPrivate) {
      console.log(`skip: ${t.name} (private)`);
      continue;
    }
    if (!t.hasDist) {
      console.log(`\n=== ${t.name} (${t.dir}) ===`);
      fail(t.name, `dist/ 없음 — 빌드 선행 필요 (bun run --cwd ${t.dir} build)`);
      continue;
    }
    allNames.add(t.name);
    pkgInfos.push({ dir: t.absDir, pkg: t.pkg });
  }

  // tarball 생성 + workspaceDeps 해결
  const tarballDir = join(tmpRoot, 'tarballs');
  await mkdir(tarballDir, { recursive: true });
  for (const { dir, pkg } of pkgInfos) {
    const tarball = packTarball(dir, tarballDir);
    if (!tarball) {
      fail(pkg.name, `bun pm pack 실패`);
      continue;
    }
    targets.push({
      dir,
      name: pkg.name,
      tarballPath: tarball,
      workspaceDeps: collectWorkspaceDeps(pkg, allNames),
    });
  }
  return targets;
}

function tarballOf(targets: TargetInfo[], name: string): string | null {
  return targets.find((t) => t.name === name)?.tarballPath ?? null;
}

async function installOne(target: TargetInfo, allTargets: TargetInfo[], tmpRoot: string): Promise<void> {
  const installDir = join(tmpRoot, `install-${target.name.replace(/[/@]/g, '_')}`);
  await mkdir(installDir, { recursive: true });

  // 빈 package.json 생성
  await writeFile(
    join(installDir, 'package.json'),
    JSON.stringify({ name: 'smoke-test-app', version: '0.0.0', type: 'module' }, null, 2),
  );

  // 자기 + workspace deps 의 tarball 모두 file: 로 install
  const installArgs = [target.tarballPath];
  for (const depName of target.workspaceDeps) {
    const tb = tarballOf(allTargets, depName);
    if (!tb) {
      fail(target.name, `workspace dep "${depName}" 의 tarball 못 찾음`);
      return;
    }
    installArgs.push(tb);
  }

  // npm install — bun install 은 file: tarball 처리에 한계가 있어 npm 사용
  const installRes = spawnSync('npm', ['install', '--no-audit', '--no-fund', '--silent', ...installArgs], {
    cwd: installDir,
    encoding: 'utf8',
  });
  if (installRes.status !== 0) {
    fail(target.name, `npm install 실패: ${installRes.stderr.trim().split('\n').slice(-5).join('\n')}`);
    return;
  }

  // dynamic import 로 entry 검증 — ESM 사용자가 'import X from \"@zntc/Y\"' 시
  // 정확히 동일 condition (import / default). NAPI binding 호출 / WASM init /
  // RN runtime 등 호출 시점 의존은 throw 가능 — ERR_MODULE_NOT_FOUND
  // (resolution 자체 실패) 만 fail 로 처리.
  const checkScript = `
    try {
      const m = await import(${JSON.stringify(target.name)});
      const keys = Object.keys(m);
      console.log('IMPORT OK:', keys.length, 'exports');
    } catch (e) {
      if (e && (e.code === 'ERR_MODULE_NOT_FOUND' || e.code === 'ERR_PACKAGE_PATH_NOT_EXPORTED')) {
        console.error('RESOLVE FAILED:', e.message);
        process.exit(1);
      }
      // 그 외 runtime 에러 (NAPI/WASM/RN 환경 의존) 는 resolution 자체는 OK
      console.log('IMPORT OK (resolution); runtime error 무시:', e && e.code || (e && e.message || e));
    }
  `;
  await writeFile(join(installDir, 'check.mjs'), checkScript);
  const checkRes = spawnSync('node', ['check.mjs'], { cwd: installDir, encoding: 'utf8' });
  if (checkRes.status !== 0) {
    fail(target.name, `entry resolve 실패: ${checkRes.stdout.trim()} ${checkRes.stderr.trim()}`);
    return;
  }
  ok(`install + resolve OK${target.workspaceDeps.length > 0 ? ` (workspace deps: ${target.workspaceDeps.join(', ')})` : ''}`);
}

async function main() {
  const tmpRoot = mkdtempSync(join(tmpdir(), 'zntc-install-smoke-'));
  try {
    const targets = await detectTargets(tmpRoot);
    console.log(`\nDetected ${targets.length} publishable packages\n`);
    for (const target of targets) {
      console.log(`=== ${target.name} ===`);
      try {
        await installOne(target, targets, tmpRoot);
      } catch (e) {
        fail(target.name, `예외: ${(e as Error).message}`);
      }
      console.log();
    }
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }

  console.log('────────────────');
  if (failures.length === 0) {
    console.log(`✓ 모든 install + resolve 통과`);
    return;
  }
  console.error(`❌ ${failures.length}건 실패:`);
  for (const f of failures) console.error(`  - ${f.pkg}: ${f.msg}`);
  process.exit(1);
}

await main();
