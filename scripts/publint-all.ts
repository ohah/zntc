/**
 * publint runner — root workspaces 의 모든 publishable workspace package 에
 * publint --strict 실행. 한 곳이라도 error 면 exit 1.
 *
 * publish-smoke (zntc 특화 검증) 와 publint (npm 표준 모범 사례) 는 보완 관계 —
 * publint 는 exports order, types-first, sideEffects, file extension/format 정합성
 * 등을 본다.
 *
 * 사용:
 *   bun scripts/publint-all.ts
 *
 * 사전 조건: 각 패키지가 빌드된 상태 (`dist/`).
 */

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '..');

async function main() {
  const root = JSON.parse(await readFile(join(repoRoot, 'package.json'), 'utf8'));
  const ws = (root.workspaces as string[] | undefined) ?? [];
  const targets = ws.map((w) => w.replace(/^\.\//, '')).filter((w) => w.startsWith('packages/'));

  let failed = 0;
  for (const t of targets) {
    const pkgJsonPath = resolve(repoRoot, t, 'package.json');
    if (!existsSync(pkgJsonPath)) continue;
    const pkg = JSON.parse(await readFile(pkgJsonPath, 'utf8'));
    if (pkg.private) {
      console.log(`\nskip: ${pkg.name} (private)`);
      continue;
    }
    if (!existsSync(resolve(repoRoot, t, 'dist'))) {
      console.log(`\n=== ${pkg.name} ===`);
      console.error(`  ❌ dist/ 없음 — 빌드 선행 필요 (bun run --cwd ${t} build)`);
      failed += 1;
      continue;
    }
    console.log(`\n=== ${pkg.name} (${t}) ===`);
    // --strict 모드 (warning → error 승격) 는 보류. RN runtime 의 .js (CJS,
    // ESM mode 패키지) 같은 의도된 케이스가 잡힘 — 별도 audit PR 에서 case-by-case
    // 검토 후 strict 로 전환. 본 runner 는 errors 만 강제.
    const res = spawnSync('bunx', ['publint', '--level', 'error', t], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: 'inherit',
    });
    if (res.status !== 0) failed += 1;
  }

  console.log('\n────────────────');
  if (failed === 0) {
    console.log(`✓ publint 모두 통과`);
    return;
  }
  console.error(`❌ ${failed}개 패키지에서 publint error`);
  process.exit(1);
}

await main();
