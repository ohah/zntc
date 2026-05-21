/**
 * Release script — publishable workspace package 들을 토폴로지 순서로 publish.
 *
 * 안전 기본값:
 * - default 는 dry-run (실제 publish 안 함)
 * - 실제 publish 는 `--publish` flag 명시 + stdin 'yes' confirm 모두 필요 (CI 는 --yes 로 우회)
 * - pre-release-check 통과 강제
 * - npm registry 에 이미 같은 version 이 publish 됐으면 그 패키지 skip (idempotent)
 * - sub-package (`@zntc/core-{platform}`) 의 zntc.node 누락/빈 파일 검증 — 빈 binary publish 차단
 *
 * 사용:
 *   bun scripts/release.ts                       # dry-run, 변경 없음
 *   bun scripts/release.ts --publish             # confirm 후 실제 publish (--access public)
 *   bun scripts/release.ts --publish --yes       # confirm prompt 우회 (CI/release.yml 자동화)
 *   bun scripts/release.ts --publish --tag next  # dist-tag 'next' 로
 *
 * publish 순서: platform sub-package 5개 (no deps, main 의 optionalDependencies)
 *   → core → server (skip, private) → web / react-native / @zntc/vite-plugin / @zntc/rspack-loader / wasm / init
 */

import { spawnSync } from 'node:child_process';
import { existsSync, statSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { createInterface } from 'node:readline/promises';
import { dirname, join, resolve } from 'node:path';
import { stdin, stdout } from 'node:process';
import { fileURLToPath } from 'node:url';
import { PLATFORMS, subPackageDir } from '../packages/core/src/platforms.ts';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '..');

interface ReleaseTarget {
  dir: string;
  name: string;
  version: string;
  isPlatformSubPackage: boolean;
}

// publishable 토폴로지:
//   1) platform sub-package 5개 — main 의 optionalDependencies 가 reference 하므로 먼저 publish
//   2) core — sub-package 들에 optionalDependency
//   3) core 만 의존하는 패키지들
const PUBLISH_ORDER = [
  ...PLATFORMS.map(subPackageDir),
  'packages/core',
  'packages/web',
  'packages/react-native',
  'packages/vite-plugin',
  'packages/rspack-loader',
  'packages/wasm',
  'packages/init',
];

const PLATFORM_SUB_DIRS = new Set(PLATFORMS.map(subPackageDir));

// sub-package 디렉토리 안 zntc.node 가 정상 binary 인지 확인 — 빈 placeholder
// publish 차단. release.yml 매트릭스 빌드가 실제 binary 로 채워야 통과.
// sub-package 의 prepublishOnly hook (`scripts/check-platform-binary.mjs`) 와
// 같은 검증 — defense-in-depth.
function verifySubPackageBinary(dir: string, name: string): void {
  const res = spawnSync('node', [resolve(__dirname, 'check-platform-binary.mjs'), 'zntc.node'], {
    cwd: resolve(repoRoot, dir),
    encoding: 'utf8',
  });
  if (res.status !== 0) {
    throw new Error(`${name}: ${res.stderr.trim() || 'binary 검증 실패'}`);
  }
}

async function loadTargets(): Promise<ReleaseTarget[]> {
  const targets: ReleaseTarget[] = [];
  for (const dir of PUBLISH_ORDER) {
    const pkgJsonPath = resolve(repoRoot, dir, 'package.json');
    if (!existsSync(pkgJsonPath)) {
      console.warn(`skip: ${dir} (package.json 없음)`);
      continue;
    }
    const pkg = JSON.parse(await readFile(pkgJsonPath, 'utf8'));
    if (pkg.private) {
      console.log(`skip: ${pkg.name} (private)`);
      continue;
    }
    targets.push({
      dir,
      name: pkg.name,
      version: pkg.version,
      isPlatformSubPackage: PLATFORM_SUB_DIRS.has(dir),
    });
  }
  return targets;
}

function checkRegistry(name: string, version: string): 'available' | 'taken' | 'unknown' {
  // `npm view <name>@<version> version` — 존재 시 stdout 에 version, 없으면 빈
  // stdout + non-zero exit (404 류). 둘 다 catch.
  const res = spawnSync('npm', ['view', `${name}@${version}`, 'version', '--json'], {
    encoding: 'utf8',
  });
  if (res.status === 0 && res.stdout.trim().length > 0) return 'taken';
  if (res.stderr.includes('E404') || res.stderr.includes('Not found')) return 'available';
  return 'unknown';
}

async function confirm(prompt: string): Promise<boolean> {
  const rl = createInterface({ input: stdin, output: stdout });
  const answer = await rl.question(prompt);
  rl.close();
  return answer.trim().toLowerCase() === 'yes';
}

async function main() {
  const args = process.argv.slice(2);
  const isPublish = args.includes('--publish');
  const isYes = args.includes('--yes');
  const tagIdx = args.indexOf('--tag');
  const tag = tagIdx >= 0 ? args[tagIdx + 1] : undefined;

  console.log('=== ZNTC release ===');
  console.log(`mode: ${isPublish ? 'PUBLISH (실제 publish)' : 'dry-run (변경 없음)'}`);
  if (tag) console.log(`tag: ${tag}`);
  if (isYes) console.log('confirm: --yes (prompt 우회)');
  console.log();

  // 1. pre-release-check 먼저 실행
  console.log('--- pre-release-check ---');
  const checkRes = spawnSync('bun', ['run', 'pre-release-check'], {
    cwd: repoRoot,
    stdio: 'inherit',
  });
  if (checkRes.status !== 0) {
    throw new Error('pre-release-check 실패 — release 중단');
  }
  console.log('\n✓ pre-release-check 통과\n');

  // 2. 대상 목록
  const targets = await loadTargets();
  console.log('--- 대상 publishable 패키지 ---');
  for (const t of targets) console.log(`  - ${t.name}@${t.version}  (${t.dir})`);
  console.log();

  // 3. registry 가용성 확인
  console.log('--- registry 가용성 ---');
  const skipPackages = new Set<string>();
  for (const t of targets) {
    const status = checkRegistry(t.name, t.version);
    const label = status === 'available'
      ? '🟢 available (publish 가능)'
      : status === 'taken'
        ? '🟡 taken (이미 publish 됨 — skip)'
        : '⚪ unknown (network/registry 응답 이상 — 진행 시도)';
    console.log(`  - ${t.name}@${t.version}: ${label}`);
    if (status === 'taken') skipPackages.add(t.name);
  }
  console.log();

  // 4. dry-run 이면 여기서 종료
  if (!isPublish) {
    console.log('=== dry-run 종료 ===');
    console.log('실제 publish 하려면 `bun scripts/release.ts --publish` 사용');
    return;
  }

  // 5. confirm prompt
  const toPublish = targets.filter((t) => !skipPackages.has(t.name));
  if (toPublish.length === 0) {
    console.log('publish 할 패키지 없음 (모두 이미 registry 에 있거나 private).');
    return;
  }
  console.log('실제 publish 대상:');
  for (const t of toPublish) console.log(`  - ${t.name}@${t.version}`);
  console.log();

  // sub-package binary 무결성 검증 — 빈 placeholder publish 차단.
  for (const t of toPublish) {
    if (t.isPlatformSubPackage) verifySubPackageBinary(t.dir, t.name);
  }

  const ok = isYes || await confirm("확인하시려면 'yes' 입력 (그 외 입력 시 중단): ");
  if (!ok) {
    console.log('취소됨.');
    return;
  }

  // 6. sequential publish
  for (const t of toPublish) {
    console.log(`\n--- publishing ${t.name}@${t.version} ---`);
    const publishArgs = ['publish', '--access', 'public'];
    if (tag) publishArgs.push('--tag', tag);
    // npm publish 사용 — `bun publish` 는 setup-node/.npmrc 의 토큰 인증을 못 읽어
    // CI 에서 "missing authentication" 으로 실패한다. npm 은 .npmrc(_authToken)를
    // 표준대로 읽어 인증. prepublishOnly hook(bun run build)은 npm 도 그대로 실행.
    const res = spawnSync('npm', publishArgs, {
      cwd: resolve(repoRoot, t.dir),
      stdio: 'inherit',
    });
    if (res.status !== 0) {
      throw new Error(`${t.name} publish 실패 — 중단 (이전 패키지는 publish 됨)`);
    }
  }

  console.log('\n=== 모두 publish 완료 ===');
}

await main().catch((e: unknown) => {
  const msg = e instanceof Error ? e.message : String(e);
  console.error(`\n❌ ${msg}`);
  process.exit(1);
});
