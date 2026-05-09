/**
 * Publishable dependency version consistency check.
 *
 * sherif 의 `multiple-dependency-versions` 는 examples/benchmark 가 의도적으로
 * 다양한 RN/React 버전 시험해서 노이즈 — workspace 전역 검사는 비활성. 단
 * publishable 패키지 (실제 사용자에게 노출) 사이에선 같은 external dep 을 다른
 * version 으로 선언하면 사용자 install 시 conflict / 의도 외 동작 가능.
 *
 * 본 script: publishable 7 패키지 (server 는 private 이지만 workspace dep 으로
 * 사용되니 포함) 의 dependencies / peerDependencies / optionalDependencies 만
 * 모아 같은 external dep 이 다른 version range 로 등장하는지 검사.
 *
 * workspace:* 는 모두 동일이라 자동 OK — external dep 만 검사 의미.
 *
 * 사용:
 *   bun scripts/publishable-deps-check.ts
 */

import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, '..');

interface DepUsage {
  pkg: string;
  field: string;
  version: string;
}

const versions = new Map<string, DepUsage[]>();

function record(deps: Record<string, string> | undefined, pkg: string, field: string) {
  if (!deps) return;
  for (const [name, version] of Object.entries(deps)) {
    if (version.startsWith('workspace:')) continue;
    if (!versions.has(name)) versions.set(name, []);
    versions.get(name)!.push({ pkg, field, version });
  }
}

async function main() {
  const root = JSON.parse(await readFile(join(repoRoot, 'package.json'), 'utf8'));
  const ws = (root.workspaces as string[] | undefined) ?? [];
  const targets = ws
    .map((w) => w.replace(/^\.\//, ''))
    .filter((w) => w.startsWith('packages/'));

  for (const t of targets) {
    const pkgJsonPath = resolve(repoRoot, t, 'package.json');
    if (!existsSync(pkgJsonPath)) continue;
    const pkg = JSON.parse(await readFile(pkgJsonPath, 'utf8'));
    record(pkg.dependencies, pkg.name, 'dependencies');
    record(pkg.peerDependencies, pkg.name, 'peerDependencies');
    record(pkg.optionalDependencies, pkg.name, 'optionalDependencies');
  }

  const conflicts: string[] = [];
  for (const [dep, usages] of versions) {
    const uniqueVersions = new Set(usages.map((u) => u.version));
    if (uniqueVersions.size <= 1) continue;
    conflicts.push(`\n${dep}:`);
    for (const u of usages) {
      conflicts.push(`  - ${u.pkg} (${u.field}): ${u.version}`);
    }
  }

  if (conflicts.length === 0) {
    console.log('✓ 모든 publishable 패키지의 external dep version 이 일관됨');
    return;
  }

  console.error('❌ 일관성 깨짐:');
  for (const line of conflicts) console.error(line);
  console.error('\n→ 같은 external dep 은 모든 publishable 패키지에서 동일 range 사용 권장.');
  console.error('  의도된 차이면 본 script 의 ignore list 에 명시 (단 사용자 conflict 위험 인지).');
  process.exit(1);
}

await main();
