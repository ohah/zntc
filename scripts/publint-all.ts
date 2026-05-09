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
import { detectWorkspacePackages, repoRoot } from './lib/workspace.ts';

async function main() {
  const targets = await detectWorkspacePackages();

  let failed = 0;
  for (const t of targets) {
    if (t.isPrivate) {
      console.log(`\nskip: ${t.name} (private)`);
      continue;
    }
    if (!t.hasDist) {
      console.log(`\n=== ${t.name} ===`);
      console.error(`  ❌ dist/ 없음 — 빌드 선행 필요 (bun run --cwd ${t.dir} build)`);
      failed += 1;
      continue;
    }
    console.log(`\n=== ${t.name} (${t.dir}) ===`);
    // --strict: warning 도 error 로 승격. RN runtime 의 .js (ESM 모드 + CJS 코드)
    // case 는 .cjs 로 rename 처리됨 (#2802). 새 warning 발생 시 case 별 audit.
    const res = spawnSync('bunx', ['publint', '--strict', '--level', 'error', t.dir], {
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
