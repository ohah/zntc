/**
 * 릴리스 버전 lockstep 동기화 + 검증.
 *
 * changesets 가 `fixed` 그룹(main 7개 패키지)만 bump 하고 **못 건드리는** 것들이 있다:
 *
 *   1. root `package.json` — private + workspace 패키지가 아니라 changesets 의 시야 밖.
 *   2. platform 바이너리 9개 (`packages/core-*`) — `workspaces` 목록에 없어서 시야 밖.
 *      (workspaces 에 넣으면 `bun publish` 의 workspace→version 변환 semantics 가
 *       바뀌어 배포 경로가 흔들린다 — 그래서 일부러 뺀 채로 둔다.)
 *   3. `@zntc/core` 의 `optionalDependencies` 안 `@zntc/core-*` 버전 — 위 2번이
 *      워크스페이스가 아니라 changesets 의 internal-dep 갱신 대상이 아니다.
 *
 * 이걸 매 릴리스마다 손으로 올렸고(v0.1.2 / v0.1.3), 하나라도 빠지면 **0.1.3 core 가
 * 0.1.2 네이티브 바이너리를 받는** 치명적 불일치가 난다. 자동화한다.
 *
 * 진실의 원천 = `packages/core/package.json` 의 version (changesets 가 방금 정한 값).
 *
 * 사용:
 *   bun scripts/sync-release-versions.ts           # 동기화 (파일 수정)
 *   bun scripts/sync-release-versions.ts --check   # 검증만 (불일치 시 exit 1)
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { globSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = join(import.meta.dir, '..');
const CHECK_ONLY = process.argv.includes('--check');

interface Target {
  label: string;
  file: string;
  /** 현재 값을 읽는다. */
  read: (pkg: any) => string | undefined;
  /** 새 값을 쓴다. 바뀌었으면 true. */
  write: (pkg: any, version: string) => boolean;
}

function readPkg(file: string): any {
  return JSON.parse(readFileSync(file, 'utf8'));
}

/** 2-space + trailing newline — npm/bun 이 쓰는 형식과 동일하게 유지 (diff 최소화). */
function writePkg(file: string, pkg: any): void {
  writeFileSync(file, JSON.stringify(pkg, null, 2) + '\n');
}

// ── 진실의 원천 ────────────────────────────────────────────────
const CORE_FILE = join(ROOT, 'packages/core/package.json');
const version: string = readPkg(CORE_FILE).version;
if (!version) {
  console.error('✗ packages/core/package.json 에 version 이 없다');
  process.exit(1);
}

// ── 동기화 대상 ────────────────────────────────────────────────
const targets: Target[] = [];

// 1. root package.json
targets.push({
  label: 'root package.json',
  file: join(ROOT, 'package.json'),
  read: (p) => p.version,
  write: (p, v) => {
    if (p.version === v) return false;
    p.version = v;
    return true;
  },
});

// 2. platform 바이너리 패키지 (packages/core-darwin-arm64 등)
const platformDirs = globSync('packages/core-*/package.json', { cwd: ROOT }).sort();
if (platformDirs.length === 0) {
  console.error('✗ platform 패키지를 하나도 못 찾았다 (packages/core-*/package.json)');
  process.exit(1);
}
for (const rel of platformDirs) {
  targets.push({
    label: rel,
    file: join(ROOT, rel),
    read: (p) => p.version,
    write: (p, v) => {
      if (p.version === v) return false;
      p.version = v;
      return true;
    },
  });
}

// 3. @zntc/core 의 optionalDependencies 안 @zntc/core-* 버전
//    (browserslist / lightningcss 등 lockstep 무관한 선택 의존성은 건드리지 않는다)
targets.push({
  label: '@zntc/core optionalDependencies (@zntc/core-*)',
  file: CORE_FILE,
  read: (p) => {
    const deps = p.optionalDependencies ?? {};
    const vs = [
      ...new Set(
        Object.entries(deps)
          .filter(([k]) => k.startsWith('@zntc/core-'))
          .map(([, v]) => v as string),
      ),
    ];
    return vs.length === 1 ? vs[0] : vs.join(',');
  },
  write: (p, v) => {
    const deps = p.optionalDependencies;
    if (!deps) return false;
    let changed = false;
    for (const k of Object.keys(deps)) {
      if (!k.startsWith('@zntc/core-')) continue;
      if (deps[k] !== v) {
        deps[k] = v;
        changed = true;
      }
    }
    return changed;
  },
});

// ── 실행 ──────────────────────────────────────────────────────
console.log(`기준 version: ${version} (packages/core)\n`);

const drift: string[] = [];
let changedCount = 0;

for (const t of targets) {
  const pkg = readPkg(t.file);
  const current = t.read(pkg);

  if (CHECK_ONLY) {
    if (current !== version) {
      drift.push(`  ✗ ${t.label}: ${current ?? '(없음)'} ≠ ${version}`);
    }
    continue;
  }

  if (t.write(pkg, version)) {
    writePkg(t.file, pkg);
    console.log(`  ✓ ${t.label}: ${current} → ${version}`);
    changedCount += 1;
  }
}

if (CHECK_ONLY) {
  if (drift.length > 0) {
    console.error('✗ 버전 lockstep 불일치 — 이대로 publish 하면 core 가 엉뚱한 버전의');
    console.error('  네이티브 바이너리를 받는다.\n');
    console.error(drift.join('\n'));
    console.error('\n  고치려면: bun run sync-versions');
    process.exit(1);
  }
  console.log(`✓ lockstep 정합 — root + platform ${platformDirs.length}개 + optionalDeps 전부 ${version}`);
  process.exit(0);
}

if (changedCount === 0) {
  console.log('변경 없음 — 이미 전부 동기화됨.');
} else {
  console.log(`\n✓ ${changedCount}개 항목 동기화 완료.`);
}
