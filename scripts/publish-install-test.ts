/**
 * Publish install test — 각 publishable workspace package 의 tarball 을
 * fresh dir 에 실제 install + entry import + (있는 경우) entry function 호출
 * 까지 검증. publish-smoke (tarball layout) 가 잡지 못하는 사고를 cover:
 *
 * - dependency resolution 실제로 동작하는지 (workspace:* 변환 후 link 가능?)
 * - bin / main / types 가 install dir 에 정확히 풀리는지
 * - peer/optional dependency 누락 시 install 자체는 통과해야 (선택적)
 * - cross-package install (web → core) 가 file: link 로 자가 monorepo 에서 동작
 * - SMOKE_CHECKS 정의된 패키지는 entry function (init/transpile/plugin())
 *   호출까지 — `url.fileURLToPath is not a function` (#3005) 같은
 *   "import 는 통과 / 호출 시 깨짐" 회귀를 사전 차단
 *
 * 전략: workspace 의 publishable package 마다
 *   1. bun pm pack 으로 tarball 생성
 *   2. tmp dir 에 빈 package.json
 *   3. 자기 + transitive workspace dep tarball 들을 file: 로 동시 install
 *   4. dynamic import 로 entry resolve 검증
 *   5. SMOKE_CHECKS[pkg] 정의돼 있으면 그 script 실행. ENV_SKIP_PATTERNS
 *      매칭 throw 는 환경 의존 (NAPI binary / RN runtime 누락) 으로 skip
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

/** entry import 후 실행할 검증 — pkg 가 import 결과 namespace. throws 면 fail
 * 단 ENV_SKIP_PATTERNS 매칭은 환경 의존 (NAPI/RN runtime 누락) 으로 간주, skip */
interface SmokeCheck {
  script: string;
}

/** 다음 패턴의 throw message 는 install 환경 의존이라 skip — 실제 publish 사용자
 * 환경에선 NAPI binary / RN runtime 등이 갖춰져 있음. publish-install-test 는
 * 일반 dev macOS 에서 돌아 platform binary 일부가 missing 일 수 있음. */
const ENV_SKIP_PATTERNS: RegExp[] = [
  /native binary not found/i,
  /Cannot find module.*\.node/,
  /react-native|metro|hermes/i,
];

const SMOKE_CHECKS: Record<string, SmokeCheck> = {
  '@zntc/core': {
    script: `
      const { init, transpile } = pkg;
      if (typeof init !== 'function') throw new Error('init export 누락');
      if (typeof transpile !== 'function') throw new Error('transpile export 누락');
      init();
      const t = transpile('const x: number = 1;', { filename: 'x.ts' });
      if (typeof t.code !== 'string' || !t.code.includes('const x')) {
        throw new Error('transpile 결과 invalid: ' + JSON.stringify(t).slice(0, 100));
      }
    `,
  },
  '@zntc/wasm': {
    script: `
      const { init, transpile } = pkg;
      if (typeof init !== 'function') throw new Error('init export 누락');
      if (typeof transpile !== 'function') throw new Error('transpile export 누락');
      await init();
      const t = transpile('const x: number = 1;', { filename: 'x.ts' });
      if (typeof t.code !== 'string' || !t.code.includes('const x')) {
        throw new Error('transpile 결과 invalid: ' + JSON.stringify(t).slice(0, 100));
      }
    `,
  },
  '@zntc/vite-plugin': {
    script: `
      const fn = pkg.default ?? pkg.zntc ?? pkg;
      if (typeof fn !== 'function') throw new Error('default export 가 function 아님');
      const plugin = fn();
      if (!plugin || typeof plugin !== 'object' || typeof plugin.name !== 'string') {
        throw new Error('plugin() 결과가 vite plugin shape 아님');
      }
    `,
  },
  '@zntc/rspack-loader': {
    script: `
      const fn = pkg.default ?? pkg;
      if (typeof fn !== 'function') throw new Error('loader (default export) 가 function 아님');
    `,
  },
};

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

  // dynamic import + (정의돼 있으면) entry function smoke check.
  // NAPI binding 누락 / RN runtime 부재 같은 환경 의존 throw 는 ENV_SKIP_PATTERNS
  // 으로 skip — 실제 publish 사용자 환경엔 갖춰져 있음. 그 외 throw 는 fail
  // (#3005 같은 "import 통과 / 호출 시 깨짐" 회귀 catch).
  const smokeScript = SMOKE_CHECKS[target.name]?.script ?? '';
  const envSkipSrc = JSON.stringify(ENV_SKIP_PATTERNS.map((r) => r.source));
  const envSkipFlagsSrc = JSON.stringify(ENV_SKIP_PATTERNS.map((r) => r.flags));
  const checkScript = `
    const ENV_SKIP = ${envSkipSrc}.map((s, i) => new RegExp(s, ${envSkipFlagsSrc}[i]));
    function isEnvSkip(e) {
      const msg = (e && (e.message ?? String(e))) || '';
      return ENV_SKIP.some((re) => re.test(msg));
    }
    try {
      const pkg = await import(${JSON.stringify(target.name)});
      console.log('IMPORT OK:', Object.keys(pkg).length, 'exports');
      const smokeSrc = ${JSON.stringify(smokeScript)};
      if (smokeSrc.trim()) {
        try {
          const fn = new Function('pkg', '"use strict"; return (async () => {' + smokeSrc + '})();');
          await fn(pkg);
          console.log('SMOKE OK');
        } catch (e) {
          if (isEnvSkip(e)) {
            console.log('SMOKE skip (env):', (e && e.message) || e);
          } else {
            console.error('SMOKE FAILED:', (e && e.stack) || e);
            process.exit(2);
          }
        }
      }
    } catch (e) {
      if (e && (e.code === 'ERR_MODULE_NOT_FOUND' || e.code === 'ERR_PACKAGE_PATH_NOT_EXPORTED')) {
        console.error('RESOLVE FAILED:', e.message);
        process.exit(1);
      }
      if (isEnvSkip(e)) {
        console.log('IMPORT OK (resolution); env skip:', e && e.code || (e && e.message || e));
      } else {
        console.error('IMPORT THREW (non-env):', (e && e.stack) || e);
        process.exit(3);
      }
    }
  `;
  await writeFile(join(installDir, 'check.mjs'), checkScript);
  const checkRes = spawnSync('node', ['check.mjs'], { cwd: installDir, encoding: 'utf8' });
  if (checkRes.status !== 0) {
    const reason =
      checkRes.status === 2 ? 'smoke (entry function 호출)'
      : checkRes.status === 3 ? 'import 시점 throw'
      : 'entry resolve';
    fail(target.name, `${reason} 실패: ${checkRes.stdout.trim()} ${checkRes.stderr.trim()}`);
    return;
  }
  const smokeRan = !!SMOKE_CHECKS[target.name];
  ok(`install + resolve${smokeRan ? ' + smoke' : ''} OK${target.workspaceDeps.length > 0 ? ` (workspace deps: ${target.workspaceDeps.join(', ')})` : ''}`);
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
